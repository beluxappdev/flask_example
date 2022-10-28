#!/bin/bash
#
# tasks performed:
#
# - creates a local Docker image with an encrypted Python program (flask patient service) and encrypted input file
# - pushes a new session to a CAS instance
# - creates a file with the session name
#
# show what we do (-x), export all varialbes (-a), and abort of first error (-e)

set -x -a -e
trap "echo Unexpected error! See log above; exit 1" ERR

# CONFIG Parameters (might change)

export IMAGE=${IMAGE:-flask_restapi_image}
export SCONE_CAS_ADDR="scone-cas.cf"
export DEVICE="/dev/sgx_enclave"

export CAS_MRENCLAVE="3061b9feb7fa67f3815336a085f629a13f04b0a1667c93b14ff35581dc8271e4"

export CLI_IMAGE="registry.scontain.com:5050/sconecuratedimages/kubernetes:hello-k8s-scone0.3"
export PYTHON_IMAGE="registry.scontain.com:5050/sconecuratedimages/public-apps:python-3.7.3-alpine3.10"
export PYTHON_MRENCLAVE="2f7f82345b032157698fb78f9abae2d3c9aab2023f5e2255d2d54f23a50eb457"
export REDIS_IMAGE="registry.scontain.com:5050/clenimar/azure-integration-demo:redis6-scone5.2.1"
export REDIS_MRENCLAVE="32c0dcbbfcfc951fc21c8f611227e50593e5e759c1d659c63575078c35fadb9b"

# create random and hence, uniquee session number
FLASK_SESSION="FlaskSession-$RANDOM-$RANDOM-$RANDOM"
REDIS_SESSION="RedisSession-$RANDOM-$RANDOM-$RANDOM"

# create directories for encrypted files and fspf
rm -rf encrypted-files
rm -rf native-files
rm -rf fspf-file

mkdir native-files/
mkdir encrypted-files/
mkdir fspf-file/
cp fspf.sh fspf-file
cp rest_api.py native-files/

# ensure that we have an up-to-date image
docker pull $CLI_IMAGE

# assume we run an SGX enabled VM


# attest cas before uploading the session file, accept CAS running in debug
# mode (-d) and outdated TCB (-G)
docker run --device=$DEVICE -i $CLI_IMAGE sh -c "
scone cas attest -G --only_for_testing-debug --only_for_testing-ignore-signer  $SCONE_CAS_ADDR $CAS_MRENCLAVE >/dev/null \
&&  scone cas show-certificate" > cas-ca.pem

# create encrypte filesystem and fspf (file system protection file)
docker run --device=$DEVICE -i -v $(pwd)/fspf-file:/fspf/fspf-file -v $(pwd)/native-files:/fspf/native-files/ -v $(pwd)/encrypted-files:/fspf/encrypted-files $CLI_IMAGE /fspf/fspf-file/fspf.sh

cat >Dockerfile <<EOF
FROM $PYTHON_IMAGE

COPY encrypted-files /fspf/encrypted-files
COPY fspf-file/fs.fspf /fspf/fs.fspf
COPY requirements.txt requirements.txt
RUN pip3 install -r requirements.txt
EOF

# create a image with encrypted flask service
docker build --pull -t $IMAGE .

# ensure that we have self-signed client certificate

if [[ ! -f client.pem || ! -f client-key.pem  ]] ; then
    openssl req -newkey rsa:4096 -days 365 -nodes -x509 -out client.pem -keyout client-key.pem -config clientcertreq.conf
fi

# create session file

export SCONE_FSPF_KEY=$(cat native-files/keytag | awk '{print $11}')
export SCONE_FSPF_TAG=$(cat native-files/keytag | awk '{print $9}')

MRENCLAVE=$REDIS_MRENCLAVE envsubst '$MRENCLAVE $REDIS_SESSION $FLASK_SESSION' < redis-template.yml > redis_session.yml
# note: this is insecure - use scone session create instead
curl -v -k -s --cert client.pem  --key client-key.pem  --data-binary @redis_session.yml -X POST https://$SCONE_CAS_ADDR:8081/session
MRENCLAVE=$PYTHON_MRENCLAVE envsubst '$MRENCLAVE $SCONE_FSPF_KEY $SCONE_FSPF_TAG $FLASK_SESSION $REDIS_SESSION' < flask-template.yml > flask_session.yml
# note: this is insecure - use scone session create instead
curl -v -k -s --cert client.pem  --key client-key.pem  --data-binary @flask_session.yml -X POST https://$SCONE_CAS_ADDR:8081/session


# create file with environment variables

cat > myenv << EOF
export FLASK_SESSION="$FLASK_SESSION"
export REDIS_SESSION="$REDIS_SESSION"
export SCONE_CAS_ADDR="$SCONE_CAS_ADDR"
export IMAGE="$IMAGE"
export DEVICE="$DEVICE"

EOF

echo "OK"
