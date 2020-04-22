#!/usr/bin/env bash

# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

TASK=$1

pushd `dirname "$0"`

LDFLAGS="-X sigs.k8s.io/secrets-store-csi-driver/pkg/secrets-store.vendorVersion=${IMAGE_VERSION} -extldflags '-static'"

# Returns list of all supported architectures from the BASEIMAGE file
listOsArchs() {
  cut -d "=" -f 1 BASEIMAGE
}

splitOsArch() {
  os_arch=$1

  if [[ $os_arch =~ .*/.*/.* ]]; then
    # for Windows, we have to support both LTS and SAC channels, so we're building multiple Windows images.
    # the format for this case is: OS/ARCH/OS_VERSION.
    os_name=$(echo "$os_arch" | cut -d "/" -f 1)
    arch=$(echo "$os_arch" | cut -d "/" -f 2)
    os_version=$(echo "$os_arch" | cut -d "/" -f 3)
    suffix="$os_name-$arch-$os_version"
  elif [[ $os_arch =~ .*/.* ]]; then
    os_name=$(echo "$os_arch" | cut -d "/" -f 1)
    arch=$(echo "$os_arch" | cut -d "/" -f 2)
    suffix="$os_name-$arch"
  else
    echo "The BASEIMAGE file is not properly formatted. Expected entries to start with 'os/arch', found '${os_arch}' instead."
    exit 1
  fi
}

# Returns baseimage need to used in Dockerfile for any given architecture
getBaseImage() {
  os_arch=$1
  file=${2:-BASEIMAGE}
  grep "${os_arch}=" "${file}" | cut -d= -f2
}

docker_version_check() {
  # The reason for this version check is even though "docker manifest" command is available in 18.03, it does
  # not work properly in that version. So we insist on 18.06.0 or higher.
  # docker buildx has been introduced in 19.03, so we need to make sure we have it.
  docker_version=$(docker version --format '{{.Client.Version}}' | cut -d"-" -f1)
  if [[ ${docker_version} != 19.03.0 && ${docker_version} < 19.03.0 ]]; then
    echo "Minimum docker version 19.03.0 is required for using docker buildx: ${docker_version}]"
    exit 1
  fi
}

# This function will build and push the image for all the architectures mentioned in BASEIMAGE file.
build_and_push() {
  docker_version_check

  docker buildx create --name img-builder --use
  trap "docker buildx rm img-builder" EXIT

  os_archs=$(listOsArchs)
  for os_arch in ${os_archs}; do
    splitOsArch "${os_arch}"

    echo "Building / pushing image for OS/ARCH: ${os_arch}..."

    dockerfile_name="Dockerfile"
    if [[ "$os_name" = "windows" ]]; then
      dockerfile_name="windows.Dockerfile"
    fi

    BASEIMAGE=$(getBaseImage "${os_arch}")

    # We only have BASEIMAGE_CORE for Windows images.
    BASEIMAGE_CORE=$(getBaseImage "${os_arch}" "BASEIMAGE_CORE") || true

    # NOTE(claudiub): docker buildx works for Windows images as long as it doesn't have to
    # execute RUN commands inside the Windows image.
    docker buildx build --no-cache --pull --push --platform "${os_name}/${arch}" -t "${IMAGE_TAG}-${suffix}" \
      --build-arg BASEIMAGE="${BASEIMAGE}" --build-arg BASEIMAGE_CORE="${BASEIMAGE_CORE}" \
      --build-arg TARGETARCH="${arch}" --build-arg TARGETOS="${os_name}" --build-arg LDFLAGS="${LDFLAGS}" \
      -f "${dockerfile_name}" ..
  done
}

ensure_manifest_tool() {
  if ! [[ -x "$(command -v manifest-tool)" ]]; then
    wget "https://github.com/estesp/manifest-tool/releases/download/v1.0.2/manifest-tool-linux-amd64" -O /usr/bin/manifest-tool
    chmod +x /usr/bin/manifest-tool
  fi
}

# This function will create and push the manifest list for the image
manifest() {
  ensure_manifest_tool

  echo "Building manifest list .yaml file for ${IMAGE_TAG}"
  echo "image: ${IMAGE_TAG}" > manifest.yaml
  echo "manifests:" >> manifest.yaml
  trap "rm manifest.yaml" EXIT

  os_archs=$(listOsArchs)
  for os_arch in ${os_archs}; do
    splitOsArch "${os_arch}"

    echo "
- image: ${IMAGE_TAG}-${suffix}
  platform:
    architecture: ${arch}
    os: ${os_name}" >> manifest.yaml

  # For Windows images, we also need to include the "os.version" in the manifest list, so the Windows node
  # can pull the proper image it needs.
  if [[ "$os_name" = "windows" ]]; then
    BASEIMAGE=$(getBaseImage "${os_arch}")
    # Getting the full OS version from the original image. The manifest-tool output looks like:
    # 1           - OS Vers: 10.0.17763.1217
    full_version=$(manifest-tool inspect ${BASEIMAGE} | grep 'OS Vers' | head -n 1 | awk '{print $5}') || true

    # manifest-tool handles osversion as os.version
    echo "    osversion: ${full_version}" >> manifest.yaml
  fi
  done

  echo "Manifest list .yaml file:"
  cat manifest.yaml

  manifest-tool push from-spec manifest.yaml
}

shift
eval "${TASK}"
