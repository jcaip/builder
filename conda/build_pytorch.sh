#!/usr/bin/env bash
if [[ -x "/remote/anaconda_token" ]]; then
    . /remote/anaconda_token || true
fi

set -ex

# TODO there is a LOT of duplicate code everywhere. There's duplicate code for
# mac siloing of pytorch and conda installations with wheel/build_wheel.sh.
# There's also duplicate versioning logic amongst *all* the building scripts

# Env variables that should be set
# PYTORCH_FINAL_PACKAGE_DIR
#   Absolute path (in docker space) to folder where final packages will be
#   stored.
#
# MACOS env variables that should be set
#   MAC_PACKAGE_WORK_DIR
#     Absolute path to a workdir in which to clone an isolated conda
#     installation and pytorch checkout. If the pytorch checkout already exists
#     then it will not be overwritten.
#
# WINDOWS env variables that should be set
#   WIN_PACKAGE_WORK_DIR
#     Absolute path to a workdir in which to clone an isolated conda
#     installation and pytorch checkout. If the pytorch checkout already exists
#     then it will not be overwritten.

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# Parse arguments and determine version
###########################################################
if [[ -n "$DESIRED_CUDA" && -n "$PYTORCH_BUILD_VERSION" && -n "$PYTORCH_BUILD_NUMBER" ]]; then
    desired_cuda="$DESIRED_CUDA"
    build_version="$PYTORCH_BUILD_VERSION"
    build_number="$PYTORCH_BUILD_NUMBER"
else
    if [ "$#" -ne 3 ]; then
        echo "Illegal number of parameters. Pass cuda version, pytorch version, build number"
        echo "CUDA version should be Mm with no dot, e.g. '80'"
        echo "DESIRED_PYTHON should be M.m, e.g. '2.7'"
        exit 1
    fi

    desired_cuda="$1"
    build_version="$2"
    build_number="$3"
fi
if [[ "$desired_cuda" != cpu ]]; then
  desired_cuda="$(echo $desired_cuda | tr -d cuda. )"
fi
echo "Building cuda version $desired_cuda and pytorch version: $build_version build_number: $build_number"

if [[ "$OSTYPE" == "msys" ]]; then
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.:$PATH"
fi

# Version: setup.py uses $PYTORCH_BUILD_VERSION.post$PYTORCH_BUILD_NUMBER if
# PYTORCH_BUILD_NUMBER > 1
if [[ -n "$OVERRIDE_PACKAGE_VERSION" ]]; then
    # This will be the *exact* version, since build_number<1
    build_version="$OVERRIDE_PACKAGE_VERSION"
    build_number=0
fi

# differentiate package name for cross compilation to avoid collision
if [[ -n "$CROSS_COMPILE_ARM64" ]]; then
    export PYTORCH_LLVM_PACKAGE=""
fi

export PYTORCH_BUILD_VERSION=$build_version
export PYTORCH_BUILD_NUMBER=$build_number

if [[ -z "$PYTORCH_BRANCH" ]]; then
    PYTORCH_BRANCH="v$build_version"
fi

# Fill in missing env variables
if [ -z "$ANACONDA_TOKEN" ]; then
    # Token needed to upload to the conda channel above
    echo "ANACONDA_TOKEN is unset. Please set it in your environment before running this script";
fi
if [[ -z "$ANACONDA_USER" ]]; then
    # This is the channel that finished packages will be uploaded to
    ANACONDA_USER=soumith
fi
if [[ -z "$GITHUB_ORG" ]]; then
    GITHUB_ORG='pytorch'
fi
if [[ -z "$CMAKE_ARGS" ]]; then
    # These are passed to tools/build_pytorch_libs.sh::build()
    CMAKE_ARGS=()
fi
if [[ -z "$EXTRA_CAFFE2_CMAKE_FLAGS" ]]; then
    # These are passed to tools/build_pytorch_libs.sh::build_caffe2()
    EXTRA_CAFFE2_CMAKE_FLAGS=()
fi

if [[ -z "$DESIRED_PYTHON" ]]; then
    DESIRED_PYTHON=('3.8')
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    DEVELOPER_DIR=/Applications/Xcode_13.3.1.app/Contents/Developer
fi
if [[ "$desired_cuda" == 'cpu' ]]; then
    cpu_only=1
else
    # Switch desired_cuda to be M.m to be consistent with other scripts in
    # pytorch/builder
    cuda_nodot="$desired_cuda"

    if [[ ${#cuda_nodot} -eq 2 ]]; then
        desired_cuda="${desired_cuda:0:1}.${desired_cuda:1:1}"
    elif [[ ${#cuda_nodot} -eq 3 ]]; then
        desired_cuda="${desired_cuda:0:2}.${desired_cuda:2:1}"
    else
        echo "unknown cuda version $cuda_nodot"
        exit 1
    fi
fi
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Produce macOS builds with torch.distributed support.
    # This is enabled by default on Linux, but disabled by default on macOS,
    # because it requires an non-bundled compile-time dependency (libuv
    # through gloo). This dependency is made available through meta.yaml, so
    # we can override the default and set USE_DISTRIBUTED=1.
    export USE_DISTRIBUTED=1

    # testing cross compilation
    if [[ -n "$CROSS_COMPILE_ARM64" ]]; then
        export CMAKE_OSX_ARCHITECTURES=arm64
        export USE_MKLDNN=OFF
        export USE_QNNPACK=OFF
        export BUILD_TEST=OFF
    fi
fi

echo "Will build for all Pythons: ${DESIRED_PYTHON[@]}"
echo "Will build for CUDA version: ${desired_cuda}"

SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

if [[ -z "$MAC_PACKAGE_WORK_DIR" ]]; then
    MAC_PACKAGE_WORK_DIR="$(pwd)/tmp_conda_${DESIRED_PYTHON}_$(date +%H%M%S)"
fi
if [[ "$OSTYPE" == "msys" && -z "$WIN_PACKAGE_WORK_DIR" ]]; then
    WIN_PACKAGE_WORK_DIR="$(echo $(pwd -W) | tr '/' '\\')\\tmp_conda_${DESIRED_PYTHON}_$(date +%H%M%S)"
fi

# Clone the Pytorch repo
###########################################################
if [[ "$(uname)" == 'Darwin' ]]; then
    mkdir -p "$MAC_PACKAGE_WORK_DIR" || true
    if [[ -n ${GITHUB_ACTIONS} ]]; then
        pytorch_rootdir="${PYTORCH_ROOT:-${MAC_PACKAGE_WORK_DIR}/pytorch}"
    else
        pytorch_rootdir="${MAC_PACKAGE_WORK_DIR}/pytorch"
    fi
elif [[ "$OSTYPE" == "msys" ]]; then
    mkdir -p "$WIN_PACKAGE_WORK_DIR" || true
    if [[ -n ${GITHUB_ACTIONS} ]]; then
        pytorch_rootdir="${PYTORCH_ROOT:-(realpath ${WIN_PACKAGE_WORK_DIR})\\pytorch}"
        pytorch_rootdir=$(cygpath -m "${pytorch_rootdir}")
    else
        pytorch_rootdir="$(realpath ${WIN_PACKAGE_WORK_DIR})/pytorch"
    fi
    git config --system core.longpaths true
    # The jobs are seperated on Windows, so we don't need to clone again.
    if [[ -d "$NIGHTLIES_PYTORCH_ROOT" ]]; then
        cp -R "$NIGHTLIES_PYTORCH_ROOT" "$pytorch_rootdir"
    fi
elif [[ -d '/pytorch' ]]; then
    # All docker binary builds
    pytorch_rootdir='/pytorch'
else
    # Shouldn't actually happen anywhere. Exists for builds outisde of nightly
    # infrastructure
    pytorch_rootdir="$(pwd)/root_${GITHUB_ORG}pytorch${PYTORCH_BRANCH}"
fi
if [[ ! -d "$pytorch_rootdir" ]]; then
    git clone "https://github.com/${PYTORCH_REPO}/pytorch" "$pytorch_rootdir"
    pushd "$pytorch_rootdir"
    git checkout "$PYTORCH_BRANCH"
    popd
fi
pushd "$pytorch_rootdir"
git submodule update --init --recursive
echo "Using Pytorch from "
git --no-pager log --max-count 1
popd

# Windows builds need to install conda
if [[ "$(uname)" == 'Darwin' ]]; then
    tmp_conda="${MAC_PACKAGE_WORK_DIR}/conda"
    miniconda_sh="${MAC_PACKAGE_WORK_DIR}/miniconda.sh"
    rm -rf "$tmp_conda"
    rm -f "$miniconda_sh"
    retry curl -sS https://repo.anaconda.com/miniconda/Miniconda3-py310_23.5.2-0-MacOSX-x86_64.sh -o "$miniconda_sh"
    chmod +x "$miniconda_sh" && \
        "$miniconda_sh" -b -p "$tmp_conda" && \
        rm "$miniconda_sh"
    export PATH="$tmp_conda/bin:$PATH"
    retry conda install -yq conda-build
elif [[ "$OSTYPE" == "msys" ]]; then
    export tmp_conda="${WIN_PACKAGE_WORK_DIR}\\conda"
    export miniconda_exe="${WIN_PACKAGE_WORK_DIR}\\miniconda.exe"
    rm -rf "$tmp_conda"
    rm -f "$miniconda_exe"
    curl -sSk https://repo.anaconda.com/miniconda/Miniconda3-py310_23.5.2-0-Windows-x86_64.exe -o "$miniconda_exe"
    "$SOURCE_DIR/install_conda.bat" && rm "$miniconda_exe"
    pushd $tmp_conda
    export PATH="$(pwd):$(pwd)/Library/usr/bin:$(pwd)/Library/bin:$(pwd)/Scripts:$(pwd)/bin:$PATH"
    popd
    retry conda install -yq conda-build
fi

cd "$SOURCE_DIR"

# Determine which build folder to use
###########################################################
if [[ -n "$TORCH_CONDA_BUILD_FOLDER" ]]; then
    build_folder="$TORCH_CONDA_BUILD_FOLDER"
else
    if [[ "$OSTYPE" == 'darwin'* ]]; then
        build_folder='pytorch'
    elif [[ -n "$cpu_only" ]]; then
        build_folder='pytorch-cpu'
    else
        build_folder="pytorch-$cuda_nodot"
    fi
    build_folder="$build_folder-$build_version"
fi
if [[ ! -d "$build_folder" ]]; then
    echo "ERROR: Cannot find the build_folder: $build_folder"
    exit 1
fi
meta_yaml="$build_folder/meta.yaml"
echo "Using conda-build folder $build_folder"

# Switch between CPU or CUDA configurations
###########################################################
build_string_suffix="$PYTORCH_BUILD_NUMBER"
if [[ -n "$cpu_only" ]]; then
    export USE_CUDA=0
    export CONDA_CUDATOOLKIT_CONSTRAINT=""
    export CONDA_TRITON_CONSTRAINT=""
    export MAGMA_PACKAGE=""
    export CUDA_VERSION="0.0"
    export CUDNN_VERSION="0.0"
    if [[ "$OSTYPE" != "darwin"* ]]; then
        build_string_suffix="cpu_${build_string_suffix}"
    fi
    export PYTORCH_BUILD_VARIANT="cpu"
else
    # Switch the CUDA version that /usr/local/cuda points to. This script also
    # sets CUDA_VERSION and CUDNN_VERSION
    echo "Switching to CUDA version $desired_cuda"
    export PYTORCH_BUILD_VARIANT="cuda"
    . ./switch_cuda_version.sh "$desired_cuda"
    # TODO, simplify after anaconda fixes their cudatoolkit versioning inconsistency.
    # see: https://github.com/conda-forge/conda-forge.github.io/issues/687#issuecomment-460086164
    if [[ "$desired_cuda" == "12.1" ]]; then
        export CONDA_CUDATOOLKIT_CONSTRAINT="    - pytorch-cuda >=12.1,<12.2 # [not osx]"
        export MAGMA_PACKAGE="    - magma-cuda121 # [not osx and not win]"
    elif [[ "$desired_cuda" == "11.8" ]]; then
        export CONDA_CUDATOOLKIT_CONSTRAINT="    - pytorch-cuda >=11.8,<11.9 # [not osx]"
        export MAGMA_PACKAGE="    - magma-cuda118 # [not osx and not win]"
    else
        echo "unhandled desired_cuda: $desired_cuda"
        exit 1
    fi
    if [[ "$OSTYPE" != "msys" ]]; then
        # TODO: Remove me when Triton has a proper release channel
        TRITON_VERSION=$(cat $pytorch_rootdir/.ci/docker/triton_version.txt)
        TRITON_SHORTHASH=$(cut -c1-10 $pytorch_rootdir/.github/ci_commit_pins/triton.txt)
        export CONDA_TRITON_CONSTRAINT="    - torchtriton==${TRITON_VERSION}+${TRITON_SHORTHASH} # [py < 312]"
    fi

    build_string_suffix="cuda${CUDA_VERSION}_cudnn${CUDNN_VERSION}_${build_string_suffix}"
fi

# Some tricks for sccache with conda builds on Windows
if [[ "$OSTYPE" == "msys" && "$USE_SCCACHE" == "1" ]]; then
    rm -rf /c/cb
    mkdir -p /c/cb/pytorch_1000000000000
    export CONDA_BLD_PATH="C:\\cb"
    export CONDA_BUILD_EXTRA_ARGS="--dirty"
else
    export CONDA_BUILD_EXTRA_ARGS=""
fi

# Build PyTorch with Gloo's TCP_TLS transport
if [[ "$(uname)" == 'Linux' ]]; then
    export USE_GLOO_WITH_OPENSSL=1

    # Defining and Setting _GLIBCXX_USE_CXX11_ABI flag in order to make sure we are setting
    # -fabi-version=11 flag in the pytorch CMake lists
    export _GLIBCXX_USE_CXX11_ABI=0
fi

# Loop through all Python versions to build a package for each
for py_ver in "${DESIRED_PYTHON[@]}"; do
    # TODO: Enable TLS support for 3.12 builds (or disable it for the rest
    if [[ "$(uname)" == 'Linux' && "${py_ver}" == '3.12' ]]; then
      export USE_GLOO_WITH_OPENSSL=0
    fi

    build_string="py${py_ver}_${build_string_suffix}"
    folder_tag="${build_string}_$(date +'%Y%m%d')"

    # Create the conda package into this temporary folder. This is so we can find
    # the package afterwards, as there's no easy way to extract the final filename
    # from conda-build
    output_folder="out_$folder_tag"
    rm -rf "$output_folder"
    mkdir "$output_folder"

    # We need to build the compiler activation scripts first on Windows
    if [[ "$OSTYPE" == "msys" ]]; then
        vs_package="vs$VC_YEAR"

        time VSDEVCMD_ARGS=${VSDEVCMD_ARGS[@]} \
             conda build -c "$ANACONDA_USER" \
                         --no-anaconda-upload \
                         --output-folder "$output_folder" \
                         $vs_package

        cp "$vs_package/conda_build_config.yaml" "pytorch-nightly/conda_build_config.yaml"
    fi

    # Output the meta.yaml for easy debugging
    echo 'Finalized meta.yaml is'
    cat "$meta_yaml"

    # Build the package
    echo "Build $build_folder for Python version $py_ver"
    conda config --set anaconda_upload no

    if [[ "$OSTYPE" == "msys" ]]; then
      # Don't run tests on windows (they were ignored mostly anyways)
      NO_TEST="--no-test"
      # Fow windows need to keep older conda version
      conda install -y conda-package-handling conda==22.9.0
    else
      conda install -y conda-package-handling conda==23.5.2
      # NS: To be removed after conda docker images are updated
      conda update -y conda-build
    fi

    echo "Calling conda-build at $(date)"
    time CMAKE_ARGS=${CMAKE_ARGS[@]} \
         EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
         PYTORCH_GITHUB_ROOT_DIR="$pytorch_rootdir" \
         PYTORCH_BUILD_STRING="$build_string" \
         PYTORCH_MAGMA_CUDA_VERSION="$cuda_nodot" \
         conda build -c "$ANACONDA_USER" \
                     ${NO_TEST:-} \
                     --no-anaconda-upload \
                     --python "$py_ver" \
                     --output-folder "$output_folder" \
                     --no-test $CONDA_BUILD_EXTRA_ARGS \
                     "$build_folder"
    echo "Finished conda-build at $(date)"

    # Create a new environment to test in
    # TODO these reqs are hardcoded for pytorch-nightly
    test_env="env_$folder_tag"
    retry conda create -yn "$test_env" python="$py_ver"
    source activate "$test_env"

    # Extract the package for testing
    ls -lah "$output_folder"
    built_package="$(find $output_folder/ -name '*pytorch*.tar.bz2')"
    # Set correct platform for cross compiled package
    if [[ -n "$CROSS_COMPILE_ARM64" ]]; then
      conda convert "$built_package" -p osx-arm64 -f --output-dir "$output_folder"
      built_package="$(find $output_folder/osx-arm64 -name '*pytorch*.tar.bz2')"
    fi

    # Copy the built package to the host machine for persistence before testing
    if [[ -n "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
        mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true
        cp "$built_package" "$PYTORCH_FINAL_PACKAGE_DIR/"
    fi

    # Install the built package and run tests, unless it's for mac cross compiled arm64
    if [[ -z "$CROSS_COMPILE_ARM64" ]]; then
        # Install the package as if from local repo instead of tar.bz2 directly in order
        # to trigger runtime dependency installation. See https://github.com/conda/conda/issues/1884
        # Notes:
        # - pytorch-nightly is included to install torchtriton
        # - nvidia is included for cuda builds, there's no harm in listing the channel for cpu builds
        if [[ "$OSTYPE" == "msys" ]]; then
          # note the extra slash: `pwd -W` returns `c:/path/to/dir`, we need to add an extra slash for the URI
          local_channel="/$(pwd -W)/$output_folder"
        else
          local_channel="$(pwd)/$output_folder"
        fi
        conda install -y -c "file://$local_channel" pytorch==$PYTORCH_BUILD_VERSION -c pytorch -c numba/label/dev -c pytorch-nightly -c nvidia

        echo "$(date) :: Running tests"
        pushd "$pytorch_rootdir"
        if [[ "$cpu_only" == 1 ]]; then
            "${SOURCE_DIR}/../run_tests.sh" 'conda' "$py_ver" 'cpu'
        else
            "${SOURCE_DIR}/../run_tests.sh" 'conda' "$py_ver" "cu$cuda_nodot"
        fi
        popd
        echo "$(date) :: Finished tests"
    fi

    # Clean up test folder
    source deactivate
    conda env remove -yn "$test_env"
    rm -rf "$output_folder"
done

# Cleanup the tricks for sccache with conda builds on Windows
if [[ "$OSTYPE" == "msys" ]]; then
    # Please note sometimes we get Device or resource busy during
    # this cleanup step. We don't want to fail the build because of this
    # hence adding +e, -e around the cleanup step
    set +e
    rm -rf /c/cb/pytorch_1000000000000
    set -e
    unset CONDA_BLD_PATH
fi
unset CONDA_BUILD_EXTRA_ARGS

unset PYTORCH_BUILD_VERSION
unset PYTORCH_BUILD_NUMBER
