#!/usr/bin/env bash

# This script will create a namespace and deploy all the crds within the same
# namespace
# usage ./scripts/install-kubefed.sh -n <namespace> -d <location> -i <image_name> -s <scope>
# for a local deployment, you don't need to specify an image_name flag

set -e
 
#default values
NAMESPACE="default"
LOCATION="local"
OLM_VERSION="0.10.0"
OPERATOR_VERSION="0.1.0"
OPERATOR="kubefed-operator"
IMAGE_NAME="quay.io/openshift/kubefed-operator:v0.1.0-rc6"
OPERATOR_YAML_PATH="./deploy/operator.yaml"
CLUSTER_ROLEBINDING="./deploy/role_binding.yaml"
CSV_TMP_PATH="./tmp_csv.yaml"
SCOPE="Namespaced"

while getopts “n:d:i:s:o:” opt; do
    case $opt in
	n) NAMESPACE=$OPTARG ;;
	d) LOCATION=$OPTARG ;;
        i) IMAGE_NAME=$OPTARG ;;
        s) SCOPE=$OPTARG;;
	o) OPERATOR_VERSION=$OPTARG;;
    esac
done

#The operator version is either 0.1.0 style or 4.2 style and the csv files are named as 0.1.0.clusterserviceversion.yaml or 4.2.0.clusterserviceversion.yaml

function get_csv_file_name {
    if [ $1 == "0.1.0" ]; then
	echo "kubefed-operator.v$1.clusterserviceversion.yaml"
    else
	echo "kubefed-operator.v$1.0.clusterserviceversion.yaml"
    fi
}
    
CSV_FILE_NAME=$(get_csv_file_name "${OPERATOR_VERSION}")
echo "$CSV_FILE_NAME"
CSV_PATH="./deploy/olm-catalog/kubefed-operator/${OPERATOR_VERSION}/${CSV_FILE_NAME}"

echo "NS=$NAMESPACE"
echo "LOC=$LOCATION"
echo "Operator Image Name=$IMAGE_NAME"
echo "Scope=$SCOPE"
echo "Operator version=$OPERATOR_VERSION"

if test X"$NAMESPACE" != Xdefault; then
    # create a namespace 
    kubectl create ns ${NAMESPACE}
fi

# Install kubefed webhook CRD
kubectl apply -f ./deploy/crds/operator_v1alpha1_kubefedwebhook_crd.yaml
# Install kubefed CRD
kubectl apply -f ./deploy/crds/operator_v1alpha1_kubefed_crd.yaml

# Install the webhook CR at Cluster scope
kubectl apply -f ./deploy/crds/operator_v1alpha1_kubefedwebhook_cr.yaml -n $NAMESPACE
# Install kubefed CR based on the scope

if test X"$SCOPE" = XNamespaced; then
    sed "s,scope:.*,scope: ${SCOPE}," ./deploy/crds/operator_v1alpha1_kubefed_cr.yaml | kubectl apply -n $NAMESPACE -f -
else
    kubectl apply -f ./deploy/crds/operator_v1alpha1_kubefed_cr.yaml -n $NAMESPACE
fi

# A local deployment
if test X"$LOCATION" = Xlocal; then
  operator-sdk &> /dev/null
  if [ $? == 0 ]; then
  # operator-sdk up local command doesn't install the requried CRD's
  for f in ./deploy/crds/*_crd.yaml ; do     
	  kubectl apply -f "${f}" --validate=false 
  done
	    operator-sdk up local --namespace=$NAMESPACE &
  else
	  echo "Operator SDK is not installed."
	  exit 1
  fi

# in-cluster deployment on kind cluster
elif test X"$LOCATION" = Xcluster; then
  for f in ./deploy/*.yaml ; do
   if test X"$OPERATOR_YAML_PATH" = X"$f" ; then
      echo "Reading the image name and sed it in"
      sed "/image: /s|: .*|: ${IMAGE_NAME}|" $f | kubectl apply -n $NAMESPACE --validate=false -f -
   elif test X"$CLUSTER_ROLEBINDING" = X"$f" ; then
      echo "Reading the namespace in clusterrolebinding and sed it in"
      sed "/namespace: /s|: .*|: ${NAMESPACE}|" $f | kubectl -n $NAMESPACE apply -f -
   else
      kubectl apply -f "${f}" --validate=false -n $NAMESPACE
   fi
  done
  for f in ./deploy/crds/*_crd.yaml ; do     
	  kubectl apply -f "${f}" --validate=false 
  done
  echo "Deployed all the operator yamls for kubefed-operator in the cluster"

# olm-deployment on minikube cluster
elif test X"$LOCATION" = Xolm-kube; then
 ./scripts/kubernetes/olm-install.sh ${OLM_VERSION}
 
 echo "OLM is deployed on kube cluster"
 cp $CSV_PATH $CSV_TMP_PATH
 chmod +w $CSV_TMP_PATH
 sed "s,image: quay.*$,image: ${IMAGE_NAME}," -i $CSV_TMP_PATH
 ./hack/catalog.sh $CSV_TMP_PATH "${OPERATOR_VERSION}" | kubectl apply -n $NAMESPACE -f -
 rm $CSV_TMP_PATH
 cat <<-EOF | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubefed
  namespace: ${NAMESPACE}
spec:
 targetNamespaces:
   - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR}-sub
  generateName: ${OPERATOR}-
  namespace: ${NAMESPACE}
spec:
  source: ${OPERATOR}
  sourceNamespace: ${NAMESPACE}
  name: ${OPERATOR}
  channel: alpha
EOF
 retries=20
  until [[ $retries == 0 || $SUBSCRIPTION =~ "AtLatestKnown" ]]; do
    SUBSCRIPTION=$(kubectl get subscription -n ${NAMESPACE} -o jsonpath='{.items[*].status.state}' 2>/dev/null)
    if [[ $SUBSCRIPTION != *"AtLatestKnown"* ]]; then
        echo "Waiting for subscription to gain status"
        sleep 1
        retries=$((retries - 1))
    fi
  done
# olm deployment on openshift cluster   
elif test X"$LOCATION" = Xolm-openshift; then
 cp $CSV_PATH $CSV_TMP_PATH
 chmod +w $CSV_TMP_PATH
 sed "s,image: quay.*$,image: ${IMAGE_NAME}," -i $CSV_TMP_PATH
 ./hack/catalog.sh $CSV_TMP_PATH "${OPERATOR_VERSION}" | oc apply -n $NAMESPACE -f -
 rm $CSV_TMP_PATH
 cat <<-EOF | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubefed
  namespace: ${NAMESPACE}
spec:
 targetNamespaces:
   - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR}-sub
  generateName: ${OPERATOR}-
  namespace: ${NAMESPACE}
spec:
  source: ${OPERATOR}
  sourceNamespace: ${NAMESPACE}
  name: ${OPERATOR}
  channel: alpha
EOF
 retries=20
  until [[ $retries == 0 || $SUBSCRIPTION =~ "AtLatestKnown" ]]; do
    SUBSCRIPTION=$(kubectl get subscription -n ${NAMESPACE} -o jsonpath='{.items[*].status.state}' 2>/dev/null)
    if [[ $SUBSCRIPTION != *"AtLatestKnown"* ]]; then
        echo "Waiting for subscription to gain status"
        sleep 1
        retries=$((retries - 1))
    fi
  done
else
  echo "Please enter the valid location"
  exit 1
fi
