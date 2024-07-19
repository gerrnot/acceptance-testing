#
# Copyright The Helm Authors.
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

*** Settings ***
Documentation     Verify Helm functionality on multiple Kubernetes versions.
...
...               Fresh new kind-based clusters will be created for each
...               of the Kubernetes versions being tested. An existing
...               kind cluster can be used by specifying it in an env var
...               representing the version, for example:
...
...                  export KIND_CLUSTER_1_16_1="helm-ac-keepalive-1.16.1"
...                  export KIND_CLUSTER_1_15_4="helm-ac-keepalive-1.15.4"
...                  export KIND_CLUSTER_1_14_7="helm-ac-keepalive-1.14.7"
...
Library           String
Library           OperatingSystem
Library           ../lib/ClusterProvider.py
Library           ../lib/Kubectl.py
Library           ../lib/Helm.py
Library           ../lib/Sh.py
Suite Setup       Suite Setup
#Suite Teardown    Suite Teardown


*** Test Cases ***
#Helm works with Kubernetes 1.16.1
#    Test Helm on Kubernetes version   1.16.1

#Helm works with Kubernetes 1.15.3
#    Test Helm on Kubernetes version   1.15.3
#
[HELM-001] Helm works with Kubernetes
    @{versions} =   Split String    %{CLUSTER_VERSIONS}    ,
    FOR    ${i}    IN    @{versions}
        Set Global Variable     ${version}    ${i}
        Test Helm on Kubernetes version   ${version}
    END

*** Keyword ***
Test Helm on Kubernetes version
    Require cluster  True

    ${helm_version} =  Get Environment Variable  ROBOT_HELM_V3  "v2"
    Pass Execution If  ${helm_version} == 'v2'  Helm v2 not supported. Skipping test.

    [Arguments]    ${kube_version}
    Create test cluster with kube version    ${kube_version}

    # Add new test cases here
    Recover from a failed state
    Recover from a pending state if lock expired
    Verify concurrency works as expected
    Verify --wait flag works as expected

    ClusterProvider.Delete test cluster

Create test cluster with kube version
    [Arguments]    ${kube_version}
    ClusterProvider.Create test cluster with Kubernetes version  ${kube_version}
    ClusterProvider.Wait for cluster
    Should pass  kubectl get nodes
    Should pass  kubectl get pods --namespace=kube-system

Recover from a failed state
    # produce a release in a failed state
    Sh.Run  helm delete wait-flag-good --wait
    Helm.Upgrade test chart    wait-flag-good    nginx    True    --install --wait --timeout=15s
    Sh.Run    sleep 5
    Sh.Run    killall -TERM helm
    Sh.Run    sleep 20
    Sh.Run  helm ls -a -f wait-flag-good
    Sh.Output contains  failed

    # recover from failed state
    Helm.Upgrade test chart    wait-flag-good    nginx    False    --install --wait --timeout=120s
    Sh.Run  helm ls -a -f wait-flag-good
    Sh.Output contains  deployed

Recover from a pending state if lock expired
    # produce a release in a pending state
    Sh.Run  helm delete wait-flag-good --wait
    Helm.Upgrade test chart    wait-flag-good    nginx    True    --install --wait --timeout=15s
    Sh.Run    sleep 5
    Sh.Run    killall -KILL helm
    Sh.Run    sleep 20
    Sh.Run  helm ls -a -f wait-flag-good
    Sh.Output contains  pending-install

    # recover from pending state
    Helm.Upgrade test chart    wait-flag-good    nginx    False    --install --wait --timeout=120s
    Sh.Run  helm ls -a -f wait-flag-good
    Sh.Output contains  deployed

Verify --wait flag works as expected
    # Install nginx chart in a good state, using --wait flag
    Sh.Run  helm delete wait-flag-good --wait
    Helm.Install test chart    wait-flag-good    nginx   --wait --timeout=120s
    Helm.Return code should be  0
    Verify test chart is deployed in k8s

    # Delete good release
    Should pass  helm delete wait-flag-good

    # Install nginx chart in a bad state, using --wait flag
    Sh.Run  helm delete wait-flag-bad
    Helm.Install test chart    wait-flag-bad   nginx   --wait --timeout=60s --set breakme=true

    # Install should return non-zero, as things fail to come up
    Helm.Return code should not be  0

    # Make sure things are NOT up-and-running
    Sh.Run  kubectl get pods --namespace=default
    Sh.Run  kubectl get services --namespace=default
    Sh.Run  kubectl get pvc --namespace=default

    Kubectl.Persistent volume claim is bound    default    wait-flag-bad-nginx
    Kubectl.Return code should not be   0

    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-ext-    3
    Kubectl.Return code should not be   0
    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-fluentd-es-    1
    Kubectl.Return code should not be   0
    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-v1-    3
    Kubectl.Return code should not be   0
    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-v1beta1-    3
    Kubectl.Return code should not be   0
    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-v1beta2-    3
    Kubectl.Return code should not be   0
    Kubectl.Pods with prefix are running    default    wait-flag-bad-nginx-web-   3
    Kubectl.Return code should not be   0

    # Delete bad release
    Should pass  helm delete wait-flag-bad

Verify concurrency works as expected
    # initial chart installation so that we can perform concurrent upgrade tests later on
    Helm.Upgrade test chart    wait-flag-good    nginx    False    --install --wait --timeout=120s --set dynamicValue=initial-install
    Helm.Return code should be  0
    Verify test chart is deployed in k8s

    # first-parallel-upgrade should succeed without problems due to the locking mechanism
    # this step runs in the background!
    Helm.Upgrade test chart    wait-flag-good    nginx    True    --install --wait --timeout=120s --set dynamicValue=first-parallel-upgrade
    # give it time to start the upgrade, but not finish, since the job runs for 15s, waiting for 7s should produce a concurrency problem for the next
    # upgrade we launch soon
    Sh.Run    sleep 7

    # second-parallel-upgrade should fail (because there is a pending-upgrade already with a valid lock)
    Helm.Upgrade test chart    wait-flag-good    nginx    False    --install --wait --timeout=120s --set dynamicValue=second-parallel-upgrade
    Helm.Return code should be  1
    Helm.Output contains  another operation (install/upgrade/rollback) is in progress

    # verify first parallel upgrade succeeded in meantime, but we need to give it some more seconds
    Sh.Run    sleep 30
    Verify test chart is deployed in k8s
    Sh.Run  kubectl --namespace=default get configmap wait-flag-good-nginx -o yaml
    Sh.Output contains  first-parallel-upgrade

Verify test chart is deployed in k8s
    # Make sure everything is up-and-running
    Sh.Run  kubectl get pods --namespace=default
    Sh.Run  kubectl get services --namespace=default
    Sh.Run  kubectl get pvc --namespace=default

    Kubectl.Service has IP  default    wait-flag-good-nginx
    Kubectl.Return code should be   0

    Kubectl.Persistent volume claim is bound    default    wait-flag-good-nginx
    Kubectl.Return code should be   0

    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-ext-    3
    Kubectl.Return code should be   0
    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-fluentd-es-    1
    Kubectl.Return code should be   0
    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-v1-    3
    Kubectl.Return code should be   0
    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-v1beta1-    3
    Kubectl.Return code should be   0
    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-v1beta2-    3
    Kubectl.Return code should be   0
    Kubectl.Pods with prefix are running    default    wait-flag-good-nginx-web-   3
    Kubectl.Return code should be   0

    Sh.Run  helm ls -f wait-flag-good
    Sh.Output contains  deployed

Suite Setup
    ClusterProvider.Cleanup all test clusters

Suite Teardown
    ClusterProvider.Cleanup all test clusters
