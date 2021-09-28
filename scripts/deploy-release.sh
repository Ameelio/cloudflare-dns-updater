#!/usr/bin/env bash

k8s_server ()
{
  if [ -n "${K8S_SERVER}" ]; then
    echo "--server ${K8S_SERVER}"
  else
    echo ""
  fi
}

k8s_token ()
{
  if [ -n "${K8S_TOKEN}" ]; then
    echo "--token ${K8S_TOKEN}"
  else
    echo ""
  fi
}

main ()
{
  while [[ $# -gt 0 ]]; do
    case $1 in
      -a|--all)
        ALL_FILE='Yes'
        SAVE_FILE="$2"
        APPLY_FILE="$2"
        shift
        shift
        ;;

      -s|--save-manifest)
        SAVE_FILE="$2"
        shift
        shift
        ;;

      -m|--apply-manifest)
        APPLY_FILE="$2"
        shift
        shift
        ;;
    esac
  done

  if [ -z "${SAVE_FILE}" ] && [ -z "${APPLY_FILE}" ] && [ -n "${ALL_FILE}" ]; then
    default_fliename="${RELEASE_VERSION}-${ENV}-deployment.yaml"
    SAVE_FILE="${default_fliename}"
    APPLY_FILE="${default_fliename}"
  fi

  if [ -z "${SAVE_FILE}" ] && [ -z "${APPLY_FILE}" ]; then
    echo "
    Usage:

    -a|--all [manifest-filename.yaml]
    -s|--save-manifest <manifest-filename.yaml>
    -m|--apply-manifest <manifest-filename.yaml>

    "
    exit 1
  fi

  if [ -n "${ENV}" ]; then
    if [ -d "k8s/${ENV}" ]; then
      echo "Current env (\$ENV) is '${ENV}'"
    else
      echo "Directory k8s/${ENV} does not exist. Verify \$ENV is set correctly"
      exit 3
    fi
  else
    echo "Env var \$ENV is not set. Please set and try again"
    exit 2
  fi

  if [ -n "${SAVE_FILE}" ]; then
    echo -e "\n-- Rendering manifest into file ${SAVE_FILE} --"
    cat k8s/${ENV}/*.yaml \
      | envsubst \
      > "${SAVE_FILE}"
  fi

  if [ -n "${APPLY_FILE}" ]; then
    if [ -f "${APPLY_FILE}" ]; then
      echo -e "\n-- Applying manifest file '${APPLY_FILE}' to cluster '$(k8s_server)' --"
      echo ----------------------------
      echo kubectl $(k8s_server) $(k8s_token) --certificate-authority "k8s/ca-cert/${ENV}.ca.crt" apply -f "${APPLY_FILE}"
      echo ----------------------------
      kubectl $(k8s_server) $(k8s_token) --certificate-authority "k8s/ca-cert/${ENV}.ca.crt" apply -f "${APPLY_FILE}"
    else
      echo "Manifest file '${APPLY_FILE}' does not exist!  Cannot apply to Kubernetes"
    fi
  fi
}

main "$@"
