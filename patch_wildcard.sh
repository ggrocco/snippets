#!/bin/bash

# Usage
#
# CONTEXT=prod KEY=base_64_encoded_key CRT=base_64_encoded_crt ./patch_wildcard.sh
# or
# ./patch_wildcard.sh prod base_64_encoded_key base_64_encoded_crt

if [[ -z $CONTEXT || -z $KEY || -z $CRT ]]
then
  CONTEXT=$1
  KEY=$2
  CRT=$3
else
  CONTEXT=$CONTEXT
  KEY=$KEY
  CRT=$CRT
fi

if [[ -z $CONTEXT || -z $KEY || -z $CRT ]]
then
  echo "Please pass context, base 64 encoded key and base 64 encoded crt"
  printf "Example usage:\n CONTEXT=prod KEY=base_64_encoded_key CRT=base_64_encoded_crt ./patch_wildcard.sh\n"
  printf "Xor:\n ./patch_wildcard.sh prod base_64_encoded_key base_64_encoded_crt\n"
else
  echo "Starting..."
  kubectl get secrets --context=$CONTEXT --all-namespaces | # get all secrets
    grep "wildcard-pwnhealth" | # filter by secrets that match wildcard-pwnhealth
    awk '{ print $1 }' | # print the first column (the namespace)
    xargs -n1 echo

  read -r -p "Are you sure you want to update tls for the namespaces above in context: ${CONTEXT}? [y/N] " response
  case "$response" in
      [yY][eE][sS]|[yY]) 
        kubectl get secrets --context=$CONTEXT --all-namespaces | # get all secrets
          grep "wildcard-pwnhealth" | # filter by secrets that match wildcard-pwnhealth
          awk '{ print $1 }' | # print the first column (the namespace)
          # Iterate through every namespace and update the tls.key and tls.crt value
          # for secret named: "wildcard-pwnhealth-com-tls"
          xargs -n1 kubectl patch secret \
            --context=$CONTEXT wildcard-pwnhealth-com-tls \
            --type='json' \
            -p="[{'op' : 'replace' ,'path' : '/data/tls.key' ,'value' : '${KEY}'}, {'op' : 'replace' ,'path' : '/data/tls.crt' ,'value' : '${CRT}'}]" \
            -n 
        ;;
      *)
        echo "Action canceled."
        ;;
  esac

  echo "Done..."
fi
