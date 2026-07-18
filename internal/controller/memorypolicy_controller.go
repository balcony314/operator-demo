// Copyright 2026 balcony314.
// SPDX-License-Identifier: MIT

package controller

import (
	"context"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	versioned "k8s.io/metrics/pkg/client/clientset/versioned"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	memoryv1 "github.com/balcony314/operator-demo/api/v1"
)

const (
	// finalizerName 用于 MemoryPolicy 删除时清理其添加的标记
	finalizerName = "memory.example.com/finalizer"
	// managedByAnnotation 记录标记由哪个 MemoryPolicy 添加，便于多 policy 共存与清理
	managedByAnnotation = "memory.example.com/managed-by-policy"
	// requeueInterval 是定期轮询内存用量的间隔（metrics 不触发 watch）
	requeueInterval = 30 * time.Second
)

// MemoryPolicyReconciler reconciles a MemoryPolicy object
type MemoryPolicyReconciler struct {
	client.Client
	Scheme        *runtime.Scheme
	MetricsClient versioned.Interface
	EventRecorder record.EventRecorder
	// Metrics 暴露自定义 Prometheus 指标（被标记 Pod 数等）
	Metrics *MemoryGuardMetrics
}

// +kubebuilder:rbac:groups=memory.example.com,resources=memorypolicies,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=memory.example.com,resources=memorypolicies/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=memory.example.com,resources=memorypolicies/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=metrics.k8s.io,resources=pods,verbs=get;list

// Reconcile 实现 MemoryPolicy 的调谐闭环：
//  1. 删除中时通过 finalizer 清理该 policy 添加的所有标记
//  2. 列目标命名空间下的 Pod，拉取 PodMetrics 计算内存使用率
//  3. 超阈值且未标记 -> 加 marker（label/annotation）+ 归属 annotation
//  4. 恢复且已标记且归属本 policy -> 移除 marker + 归属 annotation
//  5. 定期 RequeueAfter 轮询（metrics 非 K8s 资源，不触发 watch）
func (r *MemoryPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var policy memoryv1.MemoryPolicy
	if err := r.Get(ctx, req.NamespacedName, &policy); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// 删除中：通过 finalizer 清理标记
	if !policy.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&policy, finalizerName) {
			if err := r.cleanupPolicyMarkers(ctx, &policy); err != nil {
				return ctrl.Result{}, err
			}
			controllerutil.RemoveFinalizer(&policy, finalizerName)
			if err := r.Update(ctx, &policy); err != nil {
				return ctrl.Result{}, err
			}
			log.Info("cleaned up markers for deleted MemoryPolicy", "policy", policy.Name)
		}
		return ctrl.Result{}, nil
	}

	// 首次见到该 policy：加 finalizer 后重新入队
	if !controllerutil.ContainsFinalizer(&policy, finalizerName) {
		controllerutil.AddFinalizer(&policy, finalizerName)
		if err := r.Update(ctx, &policy); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil
	}

	// 列目标命名空间下的 Pod
	podList := &corev1.PodList{}
	listOpts := []client.ListOption{}
	if policy.Spec.Namespace != "" {
		listOpts = append(listOpts, client.InNamespace(policy.Spec.Namespace))
	}
	if err := r.List(ctx, podList, listOpts...); err != nil {
		return ctrl.Result{}, err
	}

	// 拉取 PodMetrics 并调谐标记（含优雅降级）
	degraded, reconcileErr := r.reconcilePods(ctx, &policy, podList)

	// 更新 status
	r.updateStatus(ctx, &policy, degraded, reconcileErr)

	if reconcileErr != nil {
		r.EventRecorder.Event(&policy, corev1.EventTypeWarning, "ReconcileFailed", reconcileErr.Error())
		return ctrl.Result{RequeueAfter: requeueInterval}, nil
	}

	return ctrl.Result{RequeueAfter: requeueInterval}, nil
}

// reconcilePods 拉取 PodMetrics，计算每个 Pod 的内存使用率并加/移标记。
// 返回 degraded=true 表示 Metrics API 不可用，已降级为 request/limit 估算；
// 返回 error 非 nil 表示调谐失败。
func (r *MemoryPolicyReconciler) reconcilePods(ctx context.Context, policy *memoryv1.MemoryPolicy, podList *corev1.PodList) (bool, error) {
	log := logf.FromContext(ctx)

	// 拉 PodMetrics；失败则降级为 request/limit 估算
	metricsList, metricsErr := r.MetricsClient.MetricsV1beta1().PodMetricses(policy.Spec.Namespace).List(ctx, metav1.ListOptions{})
	degraded := metricsErr != nil
	if degraded {
		log.Info("Metrics API unavailable, degrading to request/limit estimation", "error", metricsErr.Error())
		r.EventRecorder.Eventf(policy, corev1.EventTypeWarning, "MetricsDegraded",
			"Metrics API unavailable, using request/limit estimation: %v", metricsErr)
	}

	// usageMap: podName -> 总内存使用(bytes)；降级时为空（用 request 估算）
	usageMap := map[string]int64{}
	if !degraded {
		for _, pm := range metricsList.Items {
			var total int64
			for _, c := range pm.Containers {
				if q := c.Usage[corev1.ResourceMemory]; !q.IsZero() {
					total += q.Value()
				}
			}
			usageMap[pm.Name] = total
		}
	}

	threshold := int64(policy.Spec.Threshold)
	markerKey := policy.Spec.Marker.Key
	markerValue := policy.Spec.Marker.Value

	// 统计当前被该 policy 标记的 Pod 数（用于 Prometheus 指标）
	markedCount := 0

	for i := range podList.Items {
		pod := &podList.Items[i]
		if !pod.DeletionTimestamp.IsZero() {
			continue
		}

		// 累加所有容器的 memory.limit 与 memory.request；任一容器缺 limit 则跳过该 Pod
		var limit, request int64
		allHaveLimit := true
		for _, c := range pod.Spec.Containers {
			if q, ok := c.Resources.Limits[corev1.ResourceMemory]; ok {
				limit += q.Value()
			} else {
				allHaveLimit = false
				break
			}
			if q, ok := c.Resources.Requests[corev1.ResourceMemory]; ok {
				request += q.Value()
			}
		}
		if !allHaveLimit || limit == 0 {
			continue
		}

		// 计算使用量分子：正常取实际 usage，降级取 request 估算
		var usage int64
		hasUsage := false
		if degraded {
			// 降级：用 request/limit 估算使用率
			if request > 0 {
				usage = request
				hasUsage = true
			}
		} else {
			// 正常：取 PodMetrics 实际使用
			if u, ok := usageMap[pod.Name]; ok {
				usage = u
				hasUsage = true
			}
		}
		if !hasUsage {
			continue // 暂无 metrics 且无可估算的 request
		}

		overload := usage*100 > threshold*limit
		managed := pod.Annotations[managedByAnnotation] == policy.Name

		// 统计被标记 Pod 数（归属本 policy 且当前仍有 marker）
		if managed {
			if policy.Spec.Action == "add-label" {
				if _, ok := pod.Labels[markerKey]; ok {
					markedCount++
				}
			} else if _, ok := pod.Annotations[markerKey]; ok {
				markedCount++
			}
		}

		switch policy.Spec.Action {
		case "add-label":
			_, hasMarker := pod.Labels[markerKey]
			if overload && !hasMarker {
				ensureMapLabels(pod)
				pod.Labels[markerKey] = markerValue
				ensureMapAnnotations(pod)
				pod.Annotations[managedByAnnotation] = policy.Name
				if err := r.Update(ctx, pod); err != nil {
					log.Error(err, "failed to add label to Pod", "pod", pod.Name)
					continue
				}
				r.EventRecorder.Eventf(pod, corev1.EventTypeNormal, "MarkerAdded",
					"memory usage %d%% exceeds threshold %d%%, added label %s=%s", usage*100/limit, threshold, markerKey, markerValue)
			} else if !overload && hasMarker && managed {
				delete(pod.Labels, markerKey)
				delete(pod.Annotations, managedByAnnotation)
				if err := r.Update(ctx, pod); err != nil {
					log.Error(err, "failed to remove label from Pod", "pod", pod.Name)
					continue
				}
				r.EventRecorder.Eventf(pod, corev1.EventTypeNormal, "MarkerRemoved",
					"memory usage recovered, removed label %s", markerKey)
			}
		case "add-annotation":
			_, hasMarker := pod.Annotations[markerKey]
			if overload && !hasMarker {
				ensureMapAnnotations(pod)
				pod.Annotations[markerKey] = markerValue
				pod.Annotations[managedByAnnotation] = policy.Name
				if err := r.Update(ctx, pod); err != nil {
					log.Error(err, "failed to add annotation to Pod", "pod", pod.Name)
					continue
				}
				r.EventRecorder.Eventf(pod, corev1.EventTypeNormal, "MarkerAdded",
					"memory usage %d%% exceeds threshold %d%%, added annotation %s=%s", usage*100/limit, threshold, markerKey, markerValue)
			} else if !overload && hasMarker && managed {
				delete(pod.Annotations, markerKey)
				delete(pod.Annotations, managedByAnnotation)
				if err := r.Update(ctx, pod); err != nil {
					log.Error(err, "failed to remove annotation from Pod", "pod", pod.Name)
					continue
				}
				r.EventRecorder.Eventf(pod, corev1.EventTypeNormal, "MarkerRemoved",
					"memory recovered, removed annotation %s", markerKey)
			}
		}
	}

	// 更新 Prometheus 指标：当前被该 policy 标记的 Pod 数
	if r.Metrics != nil {
		r.Metrics.MarkedPods.WithLabelValues(policy.Name, policy.Spec.Namespace).Set(float64(markedCount))
	}
	return degraded, nil
}

// cleanupPolicyMarkers 删除 MemoryPolicy 时，移除其添加的所有标记（label/annotation + 归属 annotation）。
func (r *MemoryPolicyReconciler) cleanupPolicyMarkers(ctx context.Context, policy *memoryv1.MemoryPolicy) error {
	log := logf.FromContext(ctx)

	podList := &corev1.PodList{}
	listOpts := []client.ListOption{}
	if policy.Spec.Namespace != "" {
		listOpts = append(listOpts, client.InNamespace(policy.Spec.Namespace))
	}
	if err := r.List(ctx, podList, listOpts...); err != nil {
		return err
	}

	markerKey := policy.Spec.Marker.Key
	for i := range podList.Items {
		pod := &podList.Items[i]
		if pod.Annotations[managedByAnnotation] != policy.Name {
			continue
		}
		changed := false
		if policy.Spec.Action == "add-label" {
			if _, ok := pod.Labels[markerKey]; ok {
				delete(pod.Labels, markerKey)
				changed = true
			}
		} else if _, ok := pod.Annotations[markerKey]; ok {
			delete(pod.Annotations, markerKey)
			changed = true
		}
		if pod.Annotations != nil {
			if _, ok := pod.Annotations[managedByAnnotation]; ok {
				delete(pod.Annotations, managedByAnnotation)
				changed = true
			}
		}
		if changed {
			if err := r.Update(ctx, pod); err != nil {
				log.Error(err, "failed to clean up markers from Pod", "pod", pod.Name)
				continue
			}
		}
	}
	return nil
}

// updateStatus 在 condition 变化时更新 MemoryPolicy.status.conditions。
// degraded=true（Metrics API 不可用，已降级）或 err 非 nil 时标记 Degraded，否则 Available。
func (r *MemoryPolicyReconciler) updateStatus(ctx context.Context, policy *memoryv1.MemoryPolicy, degraded bool, err error) {
	log := logf.FromContext(ctx)

	cond := metav1.Condition{
		Type:               "Available",
		ObservedGeneration: policy.Generation,
	}
	switch {
	case err != nil:
		cond.Status = metav1.ConditionFalse
		cond.Reason = "ReconcileFailed"
		cond.Message = err.Error()
	case degraded:
		cond.Status = metav1.ConditionFalse
		cond.Reason = "MetricsDegraded"
		cond.Message = "Metrics API unavailable, using request/limit estimation"
	default:
		cond.Status = metav1.ConditionTrue
		cond.Reason = "Reconciled"
		cond.Message = "memory policy reconciled successfully"
	}

	if old := meta.FindStatusCondition(policy.Status.Conditions, cond.Type); old != nil &&
		old.Status == cond.Status && old.Reason == cond.Reason && old.Message == cond.Message {
		return
	}
	meta.SetStatusCondition(&policy.Status.Conditions, cond)
	if err := r.Status().Update(ctx, policy); err != nil {
		log.Error(err, "failed to update MemoryPolicy status")
	}
}

func ensureMapLabels(pod *corev1.Pod) {
	if pod.Labels == nil {
		pod.Labels = map[string]string{}
	}
}

func ensureMapAnnotations(pod *corev1.Pod) {
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
}

// SetupWithManager sets up the controller with the Manager.
// Watch MemoryPolicy（主资源）与 Pod（次要资源：Pod 变化触发所有 policy 重新调谐）。
func (r *MemoryPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&memoryv1.MemoryPolicy{}).
		Watches(&corev1.Pod{}, handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, _ client.Object) []reconcile.Request {
			var list memoryv1.MemoryPolicyList
			if err := r.List(ctx, &list); err != nil {
				return nil
			}
			reqs := make([]reconcile.Request, 0, len(list.Items))
			for i := range list.Items {
				p := &list.Items[i]
				reqs = append(reqs, reconcile.Request{
					NamespacedName: types.NamespacedName{Name: p.Name, Namespace: p.Namespace},
				})
			}
			return reqs
		})).
		Named("memorypolicy").
		Complete(r)
}
