ifdef DOCKER_USER
	DOCKER_IMAGE_NAME ?= ${DOCKER_USER}/actions-runner-controller
else
	DOCKER_IMAGE_NAME ?= summerwind/actions-runner-controller
endif
DOCKER_USER ?= $(shell echo ${DOCKER_IMAGE_NAME} | cut -d / -f1)
VERSION ?= dev
COMMIT_SHA = $(shell git rev-parse HEAD)
RUNNER_VERSION ?= 2.327.0
TARGETPLATFORM ?= $(shell arch)
RUNNER_NAME ?= ${DOCKER_USER}/actions-runner
RUNNER_TAG  ?= ${VERSION}
TEST_REPO ?= ${DOCKER_USER}/actions-runner-controller
TEST_ORG ?=
TEST_ORG_REPO ?=
TEST_EPHEMERAL ?= false
SYNC_PERIOD ?= 1m
USE_RUNNERSET ?=
KUBECONTEXT ?= kind-acceptance
CLUSTER ?= acceptance
CERT_MANAGER_VERSION ?= v1.1.1
KUBE_RBAC_PROXY_VERSION ?= v0.11.0
SHELLCHECK_VERSION ?= 0.10.0

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:generateEmbeddedObjectMeta=true,allowDangerousTypes=true"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

TEST_ASSETS=$(PWD)/test-assets
TOOLS_PATH=$(PWD)/.tools

OS_NAME := $(shell uname -s | tr A-Z a-z)

# The etcd packages that coreos maintain use different extensions for each *nix OS on their github release page.
# ETCD_EXTENSION: the storage format file extension listed on the release page.
# EXTRACT_COMMAND: the  appropriate CLI command for extracting this file format.
ifeq ($(OS_NAME), darwin)
ETCD_EXTENSION:=zip
EXTRACT_COMMAND:=unzip
else
ETCD_EXTENSION:=tar.gz
EXTRACT_COMMAND:=tar -xzf
endif

# default list of platforms for which multiarch image is built
ifeq (${PLATFORMS}, )
	export PLATFORMS="linux/amd64,linux/arm64"
endif

# if IMG_RESULT is unspecified, by default the image will be pushed to registry
ifeq (${IMG_RESULT}, load)
	export PUSH_ARG="--load"
	# if load is specified, image will be built only for the build machine architecture.
	export PLATFORMS="local"
else ifeq (${IMG_RESULT}, cache)
	# if cache is specified, image will only be available in the build cache, it won't be pushed or loaded
	# therefore no PUSH_ARG will be specified
else
	export PUSH_ARG="--push"
endif

all: manager

lint:
	docker run --rm -v $(PWD):/app -w /app golangci/golangci-lint:v2.1.2 golangci-lint run

GO_TEST_ARGS ?= -short

# Run tests
test: generate fmt vet manifests shellcheck
	go test $(GO_TEST_ARGS) `go list ./... | grep -v ./test_e2e_arc` -coverprofile cover.out
	go test -fuzz=Fuzz -fuzztime=10s -run=Fuzz* ./controllers/actions.summerwind.net

test-with-deps: kube-apiserver etcd kubectl
	# See https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/envtest#pkg-constants
	TEST_ASSET_KUBE_APISERVER=$(KUBE_APISERVER_BIN) \
	TEST_ASSET_ETCD=$(ETCD_BIN) \
	TEST_ASSET_KUBECTL=$(KUBECTL_BIN) \
	  make test

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go
	go build -o bin/github-runnerscaleset-listener ./cmd/ghalistener

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

run-scaleset: generate fmt vet
	CONTROLLER_MANAGER_POD_NAMESPACE=default \
	CONTROLLER_MANAGER_CONTAINER_IMAGE="${DOCKER_IMAGE_NAME}:${VERSION}" \
	go run -ldflags="-s -w -X 'github.com/actions/actions-runner-controller/build.Version=$(VERSION)'" \
	./main.go --auto-scaling-runner-set-only

# Install CRDs into a cluster
install: manifests
	kustomize build config/crd | kubectl apply --server-side -f -

# Uninstall CRDs from a cluster
uninstall: manifests
	kustomize build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests
	cd config/manager && kustomize edit set image controller=${DOCKER_IMAGE_NAME}:${VERSION}
	kustomize build config/default | kubectl apply --server-side -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: manifests-gen-crds chart-crds

manifests-gen-crds: controller-gen yq
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	make manifests-gen-crds-fix DELETE_KEY=x-kubernetes-list-type
	make manifests-gen-crds-fix DELETE_KEY=x-kubernetes-list-map-keys

manifests-gen-crds-fix: DELETE_KEY ?=
manifests-gen-crds-fix:
	#runners
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.sidecarContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.dockerdContainerResources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.workVolumeClaimTemplate.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runners.yaml
	#runnerreplicasets
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.sidecarContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.dockerdContainerResources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.workVolumeClaimTemplate.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerreplicasets.yaml
	#runnerdeployments
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.sidecarContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.dockerdContainerResources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.workVolumeClaimTemplate.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnerdeployments.yaml
	#runnersets
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.volumeClaimTemplates.items.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.workVolumeClaimTemplate.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.summerwind.dev_runnersets.yaml
	#autoscalingrunnersets
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_autoscalingrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_autoscalingrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_autoscalingrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_autoscalingrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_autoscalingrunnersets.yaml
	#ehemeralrunnersets
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.ephemeralRunnerSpec.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.ephemeralRunnerSpec.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.ephemeralRunnerSpec.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.ephemeralRunnerSpec.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunnersets.yaml
	# ephemeralrunners
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.spec.properties.ephemeralContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.spec.properties.containers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.spec.properties.initContainers.items.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunners.yaml
	$(YQ) 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.spec.properties.volumes.items.properties.ephemeral.properties.volumeClaimTemplate.properties.spec.properties.resources.properties.claims.$(DELETE_KEY))' --inplace config/crd/bases/actions.github.com_ephemeralrunners.yaml

chart-crds:
	cp config/crd/bases/*.yaml charts/actions-runner-controller/crds/
	cp config/crd/bases/actions.github.com_autoscalingrunnersets.yaml charts/gha-runner-scale-set-controller/crds/
	cp config/crd/bases/actions.github.com_autoscalinglisteners.yaml charts/gha-runner-scale-set-controller/crds/
	cp config/crd/bases/actions.github.com_ephemeralrunnersets.yaml charts/gha-runner-scale-set-controller/crds/
	cp config/crd/bases/actions.github.com_ephemeralrunners.yaml charts/gha-runner-scale-set-controller/crds/
	rm charts/actions-runner-controller/crds/actions.github.com_autoscalingrunnersets.yaml
	rm charts/actions-runner-controller/crds/actions.github.com_autoscalinglisteners.yaml
	rm charts/actions-runner-controller/crds/actions.github.com_ephemeralrunnersets.yaml
	rm charts/actions-runner-controller/crds/actions.github.com_ephemeralrunners.yaml

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile=./hack/boilerplate.go.txt paths="./..."

# Run shellcheck on runner scripts
shellcheck: shellcheck-install
	$(TOOLS_PATH)/shellcheck --shell bash --source-path runner runner/*.sh runner/update-status hack/*.sh

docker-buildx:
	export DOCKER_CLI_EXPERIMENTAL=enabled ;\
	export DOCKER_BUILDKIT=1
	@if ! docker buildx ls | grep -q container-builder; then\
		docker buildx create --platform ${PLATFORMS} --name container-builder --use;\
	fi
	docker buildx build --platform ${PLATFORMS} \
		--build-arg RUNNER_VERSION=${RUNNER_VERSION} \
		--build-arg DOCKER_VERSION=${DOCKER_VERSION} \
		--build-arg VERSION=${VERSION} \
		--build-arg COMMIT_SHA=${COMMIT_SHA} \
		-t "${DOCKER_IMAGE_NAME}:${VERSION}" \
		-f Dockerfile \
		. ${PUSH_ARG}

# Push the docker image
docker-push:
	docker push ${DOCKER_IMAGE_NAME}:${VERSION}
	docker push ${RUNNER_NAME}:${RUNNER_TAG}

# Generate the release manifest file
release: manifests
	cd config/manager && kustomize edit set image controller=${DOCKER_IMAGE_NAME}:${VERSION}
	mkdir -p release
	kustomize build config/default > release/actions-runner-controller.yaml

.PHONY: release/clean
release/clean:
	rm -rf release

.PHONY: acceptance
acceptance: release/clean acceptance/pull docker-build release
	ACCEPTANCE_TEST_SECRET_TYPE=token make acceptance/run
	ACCEPTANCE_TEST_SECRET_TYPE=app make acceptance/run
	ACCEPTANCE_TEST_DEPLOYMENT_TOOL=helm ACCEPTANCE_TEST_SECRET_TYPE=token make acceptance/run
	ACCEPTANCE_TEST_DEPLOYMENT_TOOL=helm ACCEPTANCE_TEST_SECRET_TYPE=app make acceptance/run

acceptance/run: acceptance/kind acceptance/load acceptance/setup acceptance/deploy acceptance/tests acceptance/teardown

acceptance/kind:
	kind create cluster --name ${CLUSTER} --config acceptance/kind.yaml

# Set TMPDIR to somewhere under $HOME when you use docker installed with Ubuntu snap
# Otherwise `load docker-image` fail while running `docker save`.
# See https://kind.sigs.k8s.io/docs/user/known-issues/#docker-installed-with-snap
acceptance/load:
	kind load docker-image ${DOCKER_IMAGE_NAME}:${VERSION} --name ${CLUSTER}
	kind load docker-image quay.io/brancz/kube-rbac-proxy:$(KUBE_RBAC_PROXY_VERSION) --name ${CLUSTER}
	kind load docker-image ${RUNNER_NAME}:${RUNNER_TAG} --name ${CLUSTER}
	kind load docker-image docker:dind --name ${CLUSTER}
	kind load docker-image quay.io/jetstack/cert-manager-controller:$(CERT_MANAGER_VERSION) --name ${CLUSTER}
	kind load docker-image quay.io/jetstack/cert-manager-cainjector:$(CERT_MANAGER_VERSION) --name ${CLUSTER}
	kind load docker-image quay.io/jetstack/cert-manager-webhook:$(CERT_MANAGER_VERSION) --name ${CLUSTER}
	kubectl cluster-info --context ${KUBECONTEXT}
