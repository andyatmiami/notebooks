#! /usr/bin/env bash

## Description:
## 
## This script is intended to be invoked via the Makefile test-% target of the notebooks repository and assumes the deploy9-% target
## has been previously executed.  It replaces the legacy 'test_with_papermill' function previously defined in the Makefile.
##
## The script will first check to ensure a notebook workload is running and have a k8s service object exposed.  Once verified:
##  - a version_overrides.ini will be copied into the running pod if it is defined in jupyter/*/test/version_overrides.ini
##  - a test_notebook.ipynb will be copied into the running pod if it is defined in jupyter/*/test/test_notebook.ipynb
##      - for images in inherit from the datascience workbench image, the minimal and datascience notebook test files are
##          sequentially copied into the running pod
##  - for each test_notebook.ipynb file that is copied into the running pod, a test suite is invoked via papermill
##      - test execution is considered failed if the papermill output contains the string 'FAILED'
##
## Currently this script only supports jupyter notebooks running on ubi9.
##
## Dependencies: 
##     
##    - kubectl:    https://kubernetes.io/docs/reference/kubectl/
##      - a local copy of kubectl is downloaded via the Makefile bin/kubectl target, and stored in bin/kubectl within the notebooks repo
##    - wget:       https://www.man7.org/linux/man-pages/man1/wget.1.html
##    - curl:       https://www.man7.org/linux/man-pages/man1/curl.1.html
##    - pkill:      https://linux.die.net/man/1/pkill
##
## Usage: 
##
##      test_jupyter_with_papermill.sh <makefile test target> <notebook_repo_target_branch>
##          - Intended to be invoked from the test-% target of the Makefile
##          - Arguments
##              - <makefile test target>
##                  - the resolved wildcard value from the Makefile test-% pattern-matching rule
##              - <notebook_repo_target_branch>
##                  - name of the notebook repo branch to download test files
##                  - Makefile defines this as the NOTEBOOK_REPO_BASE_BRANCH variable
##  
##


set -uo pipefail

# Description: 
#   TODO
#
# Returns: 
#   Name of operating system for the notebook or empty string if not recognized
function _get_os_flavor()
{
    local full_notebook_name="${1:-}"

    local os_flavor=
    case "${full_notebook_name}" in
        *ubi9-*)
            os_flavor='ubi9' 
            ;;
        *) 
            ;;
    esac

    printf '%s' "${os_flavor}"
}

# Description: 
#   TODO
#
# Returns: 
#   Name of accelerator required for the notebook or empty string if none required
function _get_accelerator_flavor()
{
    local full_notebook_name="${1:-}"

    local accelerator_flavor=
    case "${full_notebook_name}" in
        *intel-*)
            accelerator_flavor='intel' 
            ;;
        *cuda-*) 
            ;;
        *rocm-*) 
            accelerator_flavor='rocm' 
            ;;
        *) 
            ;;
    esac

    printf '%s' "${accelerator_flavor}"
}

# Description: 
#   TODO
#
# Returns: 
#   Name of accelerator required for the notebook or empty string if none required
function _wait_for_workload()
{
    local notebook_name="${1:-}"

    "${kbin}" wait --for=condition=ready pod -l app="${notebook_name}" --timeout=600s
    "${kbin}" port-forward "svc/${notebook_name}-notebook" 8888:8888 & 
    local pf_pid=$!
    curl --retry 5 --retry-delay 5 --retry-connrefused http://localhost:8888/notebook/opendatahub/jovyan/api ; 
    kill ${pf_pid}
}

# Description: 
#   TODO
#
# Arguments: 
#   $1 : TODO
#   $2 : TODO
#   $3 : TODO
#   $4 : TODO
#   $5 : TODO
function _run_test()
{
    local notebook_repo_base_branch="${1:-}"
    local notebook_workload_name="${2:-}"
    local notebook_id="${3:-}"
    local os_flavor="${4:-}"
    local python_flavor="${5:-}"

    local test_notebook_file='test_notebook.ipynb'
    local repo_test_directory="${notebook_repo_base_branch}/jupyter/${notebook_id}/${os_flavor}-${python_flavor}/test"
    local output_file_prefix=
    output_file_prefix=$(tr '/' '-' <<< "${notebook_id}_${os_flavor}")

    "${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "python3 -m pip install papermill"
	if ! "${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "wget ${repo_test_directory}/${test_notebook_file} -O ${test_notebook_file} && python3 -m papermill ${test_notebook_file} ${output_file_prefix}_output.ipynb --kernel python3 --stderr-file ${output_file_prefix}_error.txt" ; then
		echo "ERROR: The ${notebook_id} ${os_flavor} notebook encountered a failure. To investigate the issue, you can review the logs located in the ocp-ci cluster on 'artifacts/notebooks-e2e-tests/jupyter-${notebook_id}-${os_flavor}-${python_flavor}-test-e2e' directory or run 'cat ${output_file_prefix}_error.txt' within your container. The make process has been aborted."
		exit 1
	fi  

    local test_result=
    test_result=$("${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "grep FAILED ${output_file_prefix}_error.txt" 2>&1)
    case "$?" in
        0)
            printf '\n\n%s\n' "ERROR: The ${notebook_id} ${os_flavor} notebook encountered a test failure. The make process has been aborted."
            "${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "cat ${output_file_prefix}_error.txt"
            exit 1
            ;;
        1)
            printf '\n%s\n\n' "The ${notebook_id} ${os_flavor} notebook tests run successfully"
            ;; 
        2)
            printf '\n\n%s\n' "ERROR: The ${notebook_id} ${os_flavor} notebook encountered an unexpected failure. The make process has been aborted."
            printf '%s\n\n' "${test_result}"
            exit 1
            ;;
        *)
    esac                        
}

# Description: 
#   TODO
#
# Arguments: 
#   $1 : TODO
#   $2 : TODO
#   $3 : TODO
#   $4 : TODO
function _test_datascience_notebook()
{
    local notebook_repo_base_branch="${1:-}"
    local notebook_workload_name="${2:-}"
    local os_flavor="${3:-}"
    local python_flavor="${4:-}"  

    _run_test "${notebook_repo_base_branch}" "${notebook_workload_name}" "${jupyter_minimal_notebook_id}" "${os_flavor}" "${python_flavor}"
    _run_test "${notebook_repo_base_branch}" "${notebook_workload_name}" ${jupyter_datascience_notebook_id} "${os_flavor}" "${python_flavor}"
}

# Description: 
#   TODO
#
# Arguments: 
#   $1 : TODO
#   $2 : TODO
#   $3 : TODO
#   $4 : TODO
#   $5 : TODO
function _handle_test_version_overrides()
{ 
    local notebook_repo_base_branch="${1:-}"
    local notebook_workload_name="${2:-}"
    local notebook_id="${3:-}"
    local os_flavor="${4:-}"
    local python_flavor="${5:-}" 

    local test_version_override_file='version_overrides.ini'
    local repo_test_directory="${notebook_repo_base_branch}/jupyter/${notebook_id}/${os_flavor}-${python_flavor}/test"

	if "${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "wget -q --spider ${repo_test_directory}/${test_version_override_file}" ; then
        "${kbin}" exec "${notebook_workload_name}" -- /bin/sh -c "wget ${repo_test_directory}/${test_version_override_file} -O ${test_version_override_file}"
	fi   
}

# Description: 
#   TODO
#
# Arguments: 
#   $1 : TODO
#   $2 : TODO
#   $3 : TODO
function _handle_test()
{
    local notebook_repo_base_branch="${1:-}"
    local notebook_workload_name="${2:-}"
    local python_flavor="${3:-}"

    local os_flavor=
    os_flavor=$(_get_os_flavor "${notebook_workload_name}")

    local accelerator_flavor=
    accelerator_flavor=$(_get_accelerator_flavor "${notebook_workload_name}")    

    local notebook_id=
    local extends_datascience=
    case "${notebook_workload_name}" in
        *${jupyter_minimal_notebook_id}-*)
            notebook_id="${jupyter_minimal_notebook_id}"
            ;;
        *${jupyter_datascience_notebook_id}-*) 
            notebook_id="${jupyter_datascience_notebook_id}"
            ;;      
        *-${jupyter_trustyai_notebook_id}-*) 
            notebook_id="${jupyter_trustyai_notebook_id}"
            extends_datascience='t'
            ;;   
        *-${jupyter_ml_notebook_id}-*) 
            notebook_id="${jupyter_ml_notebook_id}"
            ;;                                  
        *${jupyter_tensorflow_notebook_id}-*) 
            notebook_id="${jupyter_tensorflow_notebook_id}"
            extends_datascience='t'
            ;;
        *${jupyter_pytorch_notebook_id}-*) 
            notebook_id="${jupyter_pytorch_notebook_id}"
            extends_datascience='t'
            ;;  
        *) 
            printf '%s\n' "No matching condition found for $(notebook_workload_name)."
            exit 1
            ;;
    esac

    _handle_test_version_overrides "${notebook_repo_base_branch}" "${notebook_workload_name}" "${notebook_id}" "${os_flavor}" "${python_flavor}"

    if [ -n "${extends_datascience}" ]; then
        _test_datascience_notebook "${notebook_repo_base_branch}" "${notebook_workload_name}" "${os_flavor}" "${python_flavor}"
    fi

    if [ -n "${notebook_id}" ] && ! [ "${notebook_id}" = "${jupyter_datascience_notebook_id}" ]; then
        _run_test "${notebook_repo_base_branch}" "${notebook_workload_name}" "${notebook_id}" "${os_flavor}" "${python_flavor}"
    fi    
}

test_target="${1:-}"
notebook_repo_base_branch="${2:-"$NOTEBOOK_REPO_BASE_BRANCH"}"

jupyter_minimal_notebook_id='minimal'
jupyter_datascience_notebook_id='datascience'
jupyter_trustyai_notebook_id='trustyai'
jupyter_ml_notebook_id='ml'
jupyter_pytorch_notebook_id='pytorch'
jupyter_tensorflow_notebook_id='tensorflow'

notebook_name=$( tr '.' '-' <<< "${test_target#'cuda-'}" )
python_flavor="python-${test_target//*-python-/}"

current_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

kbin=$(readlink -f "${current_dir}/../bin/kubectl")
if ! [ -e "${kbin}" ]; then
    printf "%s" "missing bin/kubectl"
    exit 1
fi

_wait_for_workload "${notebook_name}"

notebook_workload_name=$("${kbin}" get pods -l app="${notebook_name}" -o name)

_handle_test "${notebook_repo_base_branch}" "${notebook_workload_name}" "${python_flavor}"

