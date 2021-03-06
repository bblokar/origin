#!/usr/bin/env bash
#
# Extended tests for logging in using GSSAPI

set -o errexit
set -o nounset
set -o pipefail

starttime="$(date +%s)"

project_name='gssapiproxy'
test_name="test-extended/${project_name}"

OS_ROOT="$(dirname "${BASH_SOURCE}")/../.."
cd "${OS_ROOT}"
source hack/lib/init.sh

os::build::setup_env

os::util::environment::setup_time_vars
os::util::environment::setup_all_server_vars "${test_name}"
os::util::environment::use_sudo

os::log::stacktrace::install
os::log::start_system_logger

ensure_iptables_or_die
reset_tmp_dir

# TODO(skuznets): Fix vagrant openshift so env vars can be passed to this script
JUNIT_REPORT=true

# Allow setting $JUNIT_REPORT to toggle output behavior
if [[ -n "${JUNIT_REPORT:-}" ]]; then
    export JUNIT_REPORT_OUTPUT="${LOG_DIR}/raw_test_output.log"
fi

# Always keep containers' raw output for simplicity
junit_gssapi_output="${LOG_DIR}/raw_test_output_gssapi.log"

os::test::junit::declare_suite_start "${test_name}"

os::cmd::expect_success 'hack/build-go.sh cmd/oc -tags=gssapi'
os::cmd::expect_success_and_text 'oc version' 'GSSAPI Kerberos SPNEGO'

function cleanup() {
    out=$?
    set +e
    cleanup_openshift

    # TODO(skuznets): un-hack this nonsense once traps are in a better state
    if [[ -n "${JUNIT_REPORT_OUTPUT:-}" ]]; then
      # get the jUnit output file into a workable state in case we crashed in the middle of testing something
      os::test::junit::reconcile_output

      # check that we didn't mangle jUnit output
      os::test::junit::check_test_counters

      # use the junitreport tool to generate us a report
      "${OS_ROOT}/hack/build-go.sh" tools/junitreport
      junitreport="$(os::build::find-binary junitreport)"

      if [[ -z "${junitreport}" ]]; then
          echo "It looks as if you don't have a compiled junitreport binary"
          echo
          echo "If you are running from a clone of the git repo, please run"
          echo "'./hack/build-go.sh tools/junitreport'."
          exit 1
      fi

      cat "${JUNIT_REPORT_OUTPUT}" "${junit_gssapi_output}"    \
        | "${junitreport}" --type oscmd                        \
                           --suites nested                     \
                           --roots github.com/openshift/origin \
                           --output "${ARTIFACT_DIR}/report.xml"
      cat "${ARTIFACT_DIR}/report.xml" | "${junitreport}" summarize
    fi

    endtime=$(date +%s); echo "$0 took $((endtime - starttime)) seconds"
    exit $out
}
trap "cleanup" EXIT

function update_auth_proxy_config() {
    local server_config="${1}"
    local spec='{.items[0].spec.containers[0].env[?(@.name=="SERVER")].value}'
    spec+='_'
    spec+='{.items[0].status.conditions[?(@.type=="Ready")].status}'

    os::cmd::expect_success "oc set env dc/gssapiproxy-server SERVER='${server_config}'"
    os::cmd::try_until_text "oc get pods -l deploymentconfig=gssapiproxy-server -o jsonpath='${spec}'" "^${server_config}_True$"
}

configure_os_server

# set up env vars
cp -R test/extended/testdata/gssapi "${BASETMPDIR}"
test_data_location="${BASETMPDIR}/gssapi"

host='gssapiproxy-server.gssapiproxy.svc.cluster.local'
realm="${host^^}"
backend='https://openshift.default.svc.cluster.local:443'

oauth_patch="$(sed "s/HOST_NAME/${host}/" "${test_data_location}/config/oauth_config.json")"
cp "${SERVER_CONFIG_DIR}/master/master-config.yaml" "${SERVER_CONFIG_DIR}/master/master-config.tmp.yaml"
openshift ex config patch "${SERVER_CONFIG_DIR}/master/master-config.tmp.yaml" --patch="${oauth_patch}" > "${SERVER_CONFIG_DIR}/master/master-config.yaml"
start_os_server

KUBECONFIG="${ADMIN_KUBECONFIG}"

install_registry
wait_for_registry

os::cmd::expect_success 'oc login -u system:admin'
os::cmd::expect_success "oc new-project ${project_name}"
os::cmd::expect_success "oadm policy add-scc-to-user anyuid -z default -n ${project_name}"

# create all the resources we need
os::cmd::expect_success "oc create -f '${test_data_location}/proxy'"

# kick off a build and wait for it to finish
os::cmd::expect_success "oc set env dc/gssapiproxy-server HOST='${host}' REALM='${realm}' BACKEND='${backend}'"
os::cmd::expect_success "oc start-build --from-dir='${test_data_location}/proxy' --follow gssapiproxy"

os_images=(fedora ubuntu)

for os_image in "${os_images[@]}"; do

    cp "$(which oc)" "${test_data_location}/${os_image}/base"
    cp -R "${OS_ROOT}/hack" "${test_data_location}/${os_image}/base"
    cp "${test_data_location}/scripts/test-wrapper.sh" "${test_data_location}/${os_image}/base"
    cp "${test_data_location}/scripts/gssapi-tests.sh" "${test_data_location}/${os_image}/base"
    cp "${test_data_location}/config/kubeconfig" "${test_data_location}/${os_image}/base"

    pushd "${test_data_location}/${os_image}" > /dev/null
        pushd base > /dev/null
            docker build --build-arg REALM="${realm}" --build-arg HOST="${host}" -t "${project_name}/${os_image}-gssapi-base:latest" .
        popd > /dev/null

        pushd kerberos > /dev/null
            docker build -t "${project_name}/${os_image}-gssapi-kerberos:latest" .
        popd > /dev/null

        pushd kerberos_configured > /dev/null
            docker build -t "${project_name}/${os_image}-gssapi-kerberos-configured:latest" .
        popd > /dev/null
    popd > /dev/null

done

function run_gssapi_tests() {
    local image_name="${1}"
    local server_config="${2}"
    local container_exit_code_jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'
    local pod_log_location="${LOG_DIR}/${image_name}-${server_config}.log"
    oc run "${image_name}"                                  \
            --image="${project_name}/${image_name}"         \
            --generator=run-pod/v1 --restart=Never --attach \
            --env=SERVER="${server_config}"                 \
            1> "${pod_log_location}"                        \
            2>> "${junit_gssapi_output}"
    # Lots of checks to really make sure that the tests ran successfully
    os::cmd::expect_success_and_text "cat ${pod_log_location}" 'SUCCESS'
    os::cmd::expect_success_and_not_text "cat ${pod_log_location}" 'FAILURE'
    os::cmd::expect_success_and_text "cat ${pod_log_location}" "Finished running test-extended/gssapiproxy-tests/${image_name}-CLIENT_[[:upper:]_]+-${server_config}$"
    os::cmd::try_until_text "oc get pod '${image_name}' -o jsonpath='${container_exit_code_jsonpath}'" '0' # kubelet takes time to update status
    os::cmd::expect_success "oc delete pod '${image_name}'"
}

for server_config in SERVER_GSSAPI_ONLY SERVER_GSSAPI_BASIC_FALLBACK; do

    update_auth_proxy_config "${server_config}"

    for os_image in "${os_images[@]}"; do

        run_gssapi_tests "${os_image}-gssapi-base" "${server_config}"

        run_gssapi_tests "${os_image}-gssapi-kerberos" "${server_config}"

        run_gssapi_tests "${os_image}-gssapi-kerberos-configured" "${server_config}"

    done

done

os::test::junit::declare_suite_end
