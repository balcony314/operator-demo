# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# KIND cluster name used for e2e tests
KIND_CLUSTER ?= operator-demo-test-e2e
# Platforms to build for multi-arch images
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
# Ignore not-found errors during uninstall (IGNORE_NOT_FOUND=true)
IGNORE_NOT_FOUND ?= false
# GOPROXY for docker build (e.g. GOPROXY=https://goproxy.cn,direct make docker-build)
GOPROXY ?=

# Container tool & CLIs
CONTAINER_TOOL ?= docker
KUBECTL ?= kubectl
KIND ?= kind

# Project directory & local bin
PROJECT_DIR := $(CURDIR)
LOCALBIN ?= $(PROJECT_DIR)/bin

# Tool binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint

# Tool versions
KUSTOMIZE_VERSION ?= v5.8.1
CONTROLLER_TOOLS_VERSION ?= v0.21.0
GOLANGCI_LINT_VERSION ?= v2.12.2

# ENVTEST_VERSION: from controller-runtime in go.mod (replace-aware)
ENVTEST_VERSION := $(shell go list -m sigs.k8s.io/controller-runtime 2>/dev/null | awk '{print $$2}')
# ENVTEST_K8S_VERSION: from k8s.io/api in go.mod, converted to 1.x (e.g. v0.36.0 -> 1.36)
ENVTEST_K8S_VERSION := $(shell echo $$(go list -m k8s.io/api 2>/dev/null | awk '{print $$2}') | sed -E 's/^v?[0-9]+\.([0-9]+).*/1.\1/')

# Year for generated file headers
YEAR := $(shell date +%Y)

# Use bash so that $$(...) command substitution and case/esac behave as expected.
SHELL := /usr/bin/env bash

# ============================================================
# 通用
# ============================================================

.PHONY: all
all: build ## Build manager binary

# ============================================================
# 开发
# ============================================================

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CRD manifests
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate DeepCopy methods
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt",year=$(YEAR) paths="./..."

.PHONY: fmt
fmt: ## Run go fmt
	go fmt ./...

.PHONY: vet
vet: generate ## Run go vet
	go vet ./...

.PHONY: test
test: manifests generate fmt vet setup-envtest ## Run unit tests (envtest)
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" \
	    go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

.PHONY: setup-test-e2e
setup-test-e2e: ## Create kind cluster for e2e tests if it does not exist
	@command -v $(KIND) >/dev/null 2>&1 || { echo "Kind is not installed. Please install Kind manually."; exit 1; }
	@case "$$($(KIND) get clusters)" in \
	    *"$(KIND_CLUSTER)"*) echo "Kind cluster '$(KIND_CLUSTER)' already exists. Skipping creation." ;; \
	    *) echo "Creating Kind cluster '$(KIND_CLUSTER)'..."; $(KIND) create cluster --name $(KIND_CLUSTER) ;; \
	esac

.PHONY: test-e2e
test-e2e: setup-test-e2e manifests generate fmt vet ## Run e2e tests in isolated kind environment
	KIND=$(KIND) KIND_CLUSTER=$(KIND_CLUSTER) go test -tags=e2e ./test/e2e/ -v -ginkgo.v
	$(MAKE) cleanup-test-e2e

.PHONY: cleanup-test-e2e
cleanup-test-e2e: ## Destroy the kind cluster used for e2e tests
	$(KIND) delete cluster --name $(KIND_CLUSTER)

.PHONY: integration-setup
integration-setup: ## Integration test env setup (minikube + cert-manager + metrics-server + operator)
	bash test/integration/00-setup.sh

.PHONY: integration-test
integration-test: ## Run all integration test scenarios (prereq: make integration-setup)
	bash test/integration/run-all.sh

.PHONY: integration-cleanup
integration-cleanup: ## Clean up integration test resources (--all also undeploys operator)
	bash test/integration/99-cleanup.sh $(ARGS)

.PHONY: lint
lint: golangci-lint ## Run golangci-lint
	"$(GOLANGCI_LINT)" run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint and auto-fix
	"$(GOLANGCI_LINT)" run --fix

.PHONY: lint-config
lint-config: golangci-lint ## Verify golangci-lint config
	"$(GOLANGCI_LINT)" config verify

# ============================================================
# 构建
# ============================================================

.PHONY: build
build: manifests generate fmt vet ## Build manager binary
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run controller locally
	go run ./cmd/main.go

.PHONY: docker-build
docker-build: ## Build manager docker image (e.g. GOPROXY=https://goproxy.cn,direct make docker-build)
	$(CONTAINER_TOOL) build --build-arg GOPROXY=$(GOPROXY) -t $(IMG) .

.PHONY: docker-push
docker-push: ## Push manager docker image
	$(CONTAINER_TOOL) push $(IMG)

.PHONY: docker-buildx
docker-buildx: ## Build and push manager image for multiple platforms
	sed -e '1 s/\(^FROM\)/FROM --platform=$${BUILDPLATFORM}/; t' -e ' 1,// s//FROM --platform=$${BUILDPLATFORM}/' Dockerfile > Dockerfile.cross
	-$(CONTAINER_TOOL) buildx create --name operator-demo-builder
	$(CONTAINER_TOOL) buildx use operator-demo-builder
	-$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag $(IMG) -f Dockerfile.cross .
	-$(CONTAINER_TOOL) buildx rm operator-demo-builder
	rm -f Dockerfile.cross

.PHONY: build-installer
build-installer: manifests generate kustomize ## Generate a combined YAML with CRDs and deployment
	mkdir -p dist
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default > dist/install.yaml

# ============================================================
# 部署
# ============================================================

.PHONY: install
install: manifests kustomize ## Install CRDs into the cluster
	@out="$$($(KUSTOMIZE) build config/crd 2>/dev/null || true)"; \
	if [ -n "$$out" ]; then echo "$$out" | $(KUBECTL) apply -f -; \
	else echo "No CRDs to install; skipping."; fi

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs (cleans MemoryPolicy CRs first to avoid finalizer deadlock)
	@echo "Cleaning up MemoryPolicy CR instances (if any) to avoid finalizer deadlock..."
	$(KUBECTL) delete memorypolicy.memory.example.com -A --all --ignore-not-found=$(IGNORE_NOT_FOUND) 2>/dev/null || true
	@out="$$($(KUSTOMIZE) build config/crd 2>/dev/null || true)"; \
	if [ -n "$$out" ]; then echo "$$out" | $(KUBECTL) delete --ignore-not-found=$(IGNORE_NOT_FOUND) -f -; \
	else echo "No CRDs to delete; skipping."; fi

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the cluster
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the cluster
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(IGNORE_NOT_FOUND) -f -

.PHONY: uninstall-all
uninstall-all: ## Full uninstall: undeploy + uninstall + delete namespace
	$(MAKE) undeploy
	$(MAKE) uninstall
	$(KUBECTL) delete namespace operator-demo-system --ignore-not-found=$(IGNORE_NOT_FOUND)

# ============================================================
# 依赖工具安装
# ============================================================

.PHONY: controller-gen
controller-gen: ## Download controller-gen locally if necessary
	@test -s $(CONTROLLER_GEN) || { \
	    echo "Downloading controller-gen@$(CONTROLLER_TOOLS_VERSION)"; \
	    GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION); \
	}

.PHONY: kustomize
kustomize: ## Download kustomize locally if necessary
	@test -s $(KUSTOMIZE) || { \
	    echo "Downloading kustomize@$(KUSTOMIZE_VERSION)"; \
	    GOBIN=$(LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION); \
	}

.PHONY: envtest
envtest: ## Download setup-envtest locally if necessary
	@test -s $(ENVTEST) || { \
	    echo "Downloading setup-envtest@$(ENVTEST_VERSION)"; \
	    GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@$(ENVTEST_VERSION); \
	}

.PHONY: setup-envtest
setup-envtest: envtest ## Set up envtest binaries for the configured Kubernetes version
	@echo "Setting up envtest binaries for Kubernetes version $(ENVTEST_K8S_VERSION)..."
	"$(ENVTEST)" use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path

.PHONY: golangci-lint
golangci-lint: ## Download golangci-lint locally if necessary
	@test -s $(GOLANGCI_LINT) || { \
	    echo "Downloading golangci-lint@$(GOLANGCI_LINT_VERSION)"; \
	    GOBIN=$(LOCALBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION); \
	}
	-@if [ -f .custom-gcl.yml ]; then \
	    echo "Building custom golangci-lint with plugins..."; \
	    "$(GOLANGCI_LINT)" custom --destination $(LOCALBIN) --name golangci-lint-custom; \
	    mv -f $(LOCALBIN)/golangci-lint-custom $(GOLANGCI_LINT); \
	fi

# ============================================================
# Help
# ============================================================

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make <target> [VAR=value]\n\nTargets:\n"} \
	/^[a-zA-Z_0-9-]+:.*##/ { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
