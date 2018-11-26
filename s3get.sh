#!/bin/sh

VERSION=0.0.1

usage_exit() {
    cat <<EOF
Usage: $0 [--profile XXX] [--access-key ID] [--secret-key SECRET_KEY] [--help] OBJECT_PATH OUTPUT_PATH
  -p|--proflie     : credential profile. default= "default"
  -a|--access-key  : aws access key
  -s|--secret-key  : aws secret key


  OBJECT_PATH      : download object uri
    https://s3-ap-northeast-1.amazonaws.com/BUCKET_NAME/path/to/object
    s3://bucketname/path/to/file
      load region from awscli config ( ~/.aws/config )
  OUTPUT_PATH      : save file location
    /path/to/location
    -
 if not pass -a and -s, load credentials from awscli config ( ~/.aws/credentials )
 if not pass OBJECT_PATH, please pass -b and -p
 if not pass OUTPUT_PATH, please pass -o

 
 examples
  s3cp.sh https://s3-ap-northeast-1.amazonaws.com/BUCKET_NAME/path/to/object ./save_object
    load credentials from ~/.aws/credentials ( "default" profile ) or instance meta-data
    download object to ./save_object
  s3cp.sh -a HOGEHOGE -s MOGEMOGE s3://bucket/path/to/object /path/to/save/object
    use credentials, AccessKey=HOGEHOGE SecretKey=MOGEMOGE
    load region from ~/.aws/config ( "default" profile ) or instance meta-data
    download from /bucket/path/to/object to /path/to/object
EOF
    exit 1
}

check_role_from_meta() {
    ROLE_NAME=$(curl http://169.254.169.254/latest/meta-data/iam/security-credentials/ --silent --connect-timeout 3 | grep '^[a-zA-Z0-9._-]\+$')
}

get_region_from_meta() {
    META_REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document --silent --connect-timeout 3 | grep "region" | sed 's!^.*"region" : "\([^"]\+\)".*$!\1!')
}
init_params(){
    SRC=$1
    DST=$2

    if [ -z "$SRC" -o -z "$DST" ]; then
        SRC=""
        DST=""
    fi
    
    if [ -z "$DST_PATH" -a -n "$DST" ]; then
        DST_PATH=$DST
    fi
    if [ -z "$DST_PATH" ]; then
        err_exit "please set destination path"
    fi

    if [ -z "$PROFILE" ]; then
        PROFILE=default
    fi
    if [ -z "$ACCESS_KEY" -a -z "$SECRET_KEY" ]; then
        if [ -f ~/.aws/credentials ]; then
            ACCESS_KEY=$(cat ~/.aws/credentials  | grep -P '^(\[|aws_access_key_id|aws_secret_access_key)' | grep "\[${PROFILE}\]" -A 2 | grep "^aws_access_key_id" | awk '{print $3}')
            SECRET_KEY=$(cat ~/.aws/credentials  | grep -P '^(\[|aws_access_key_id|aws_secret_access_key)' | grep "\[${PROFILE}\]" -A 2 | grep "^aws_secret_access_key" | awk '{print $3}')
        elif check_role_from_meta; then
            IAM_JSON=$(curl  http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE_NAME} --silent)
            ACCESS_KEY=$(echo "$IAM_JSON" | grep '"AccessKeyId"' | sed 's!^.\+Id" : "\([^"]\+\)",.*$!\1!')
            SECRET_KEY=$(echo "$IAM_JSON" | grep '"SecretAccessKey"' | sed 's!^.\+Key" : "\([^"]\+\)",.*$!\1!')
            TOKEN=$(echo "$IAM_JSON" | grep '"Token"' | sed 's!^.\+Token" : "\([^"]\+\)".*$!\1!')
        else
            err_exit "can not found ~/.aws/credentials"
        fi
    fi
    if [ -z "$ACCESS_KEY" -o -z "$SECRET_KEY" ]; then
        err_exit "credentials is not defined"
    fi

    if [ -n "$SRC" ]; then
        if echo "$SRC" | grep "^s3://" > /dev/null; then
            BUCKET=$(echo "$SRC" | sed 's!^s3://\([^/]\+\)/.\+$!\1!')
            SRC_PATH=$(echo "$SRC" | sed 's!^s3://[^/]\+\(/.\+\)$!\1!')
        elif echo "$SRC" | grep "^https\?://" > /dev/null; then
            S3_HOST=$(echo "$SRC" | sed 's!^https\?://\([^/]\+\)/.\+$!\1!')
            BUCKET=$(echo "$SRC" | sed 's!^https\?://[^/]\+/\([^/]\+\)/.\+$!\1!')
            SRC_PATH=$(echo "$SRC" | sed 's!^https\?://[^/]\+/[^/]\+\(/.\+\)$!\1!')
        fi
    fi
    if [ -z "$REGION" ]; then
        if [ -f ~/.aws/config ]; then
            PKEY=$PROFILE
            if [ "$PKEY" != "default" ]; then
                PKEY="profile $PKEY"
            fi
            REGION=$(cat ~/.aws/config | grep -P '^(\[|region)' | grep "\[$PKEY\]" -A 1 | grep "^region" | awk '{print $3}')
        elif get_region_from_meta; then
            REGION=$META_REGION
        else
            err_exit "can not found ~/.aws/config"
        fi
    fi
    if [ -z "$S3_HOST" ]; then
        if [ -z "$REGION" ]; then
            err_exit "please set OBJECT_PATH or awscli default region ( ~/.aws/config )"
        fi
        S3_HOST="s3-${REGION}.amazonaws.com"
    fi
    if [ -z "$SRC_PATH" ]; then
        err_exit "please set OBJECT_PATH"
    fi
}

err_exit() {
    cat <<EOF >&2
PROFILE    : $PROFILE
ACCESS_KEY : $ACCESS_KEY
SECRET_KEY : $SECRET_KEY
TOKEN      : $TOKEN
S3_HOST    : $S3_HOST
REGION     : $REGION
BUCKET     : $BUCKET
SRC_PATH   : $SRC_PATH
DST_PATH   : $DST_PATH

EOF
    echo "$@" >&2
    exit 1
}

call_api() {
    METHOD=$1
    
    DATE_VALUE=$(LC_ALL=C date +'%a, %d %b %Y %H:%M:%S %z')

    CURL_OPT=""
    if [ "$METHOD" == "GET" ]; then
        CURL_OPT="-o $DST_PATH"
    elif [ "$METHOD" == "HEAD" ]; then
        CURL_OPT="-I"
    fi
    STR2SIGN="$METHOD


$DATE_VALUE"
    if [ -n "$TOKEN" ]; then
        STR2SIGN="$STR2SIGN
x-amz-security-token:$TOKEN"
    fi
    STR2SIGN="$STR2SIGN
/${BUCKET}${SRC_PATH}"
    SIGNATURE=$(echo -en "$STR2SIGN" | openssl sha1 -hmac ${SECRET_KEY} -binary | base64)
    if [ -n "$TOKEN" ]; then
        curl -H "Host: ${S3_HOST}" \
             -H "Date: ${DATE_VALUE}" \
             -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE}" \
             -H "x-amz-security-token: $TOKEN" \
             --silent \
             $CURL_OPT \
             https://${S3_HOST}/${BUCKET}${SRC_PATH}
    else
        curl -H "Host: ${S3_HOST}" \
             -H "Date: ${DATE_VALUE}" \
             -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE}" \
             -H "x-amz-security-token: $TOKEN" \
             --silent \
             $CURL_OPT \
             https://${S3_HOST}/${BUCKET}${SRC_PATH}
    fi
}

main() {
    CHECK_RSLT=$(call_api "HEAD")
    if echo "$CHECK_RSLT" | grep "200 OK" > /dev/null; then
        call_api "GET"
    else
        err_exit "can not get object $(echo "$CHECK_RSLT" | head -n 1 )"
    fi
}


PROFILE=""
ACCESS_KEY=""
SECRET_KEY=""
S3_HOST=""
SRC_PATH=""
DST_PATH=""

OPT=$(getopt -o p:a:s:vh --long profile:,access-key:,secret-key:,version,help -- "$@")
if [ $? != 0 ]; then
    echo "$OPT"
    exit 1
fi
eval set -- "$OPT"

for x in "$@"; do
    case "$1" in
        -h | --help)
            usage_exit
            ;;
        -v | --version)
            echo "s3get.sh version ${VERSION}"
            exit
            ;;
        -p | --profile)
            PROFILE=$2
            shift 2
            ;;
        -a | --access-key)
            ACCESS_KEY=$2
            shift 2
            ;;
        -s | --secret-key)
            SECRET_KEY=$2
            shift 2
            ;;
        --)
            shift;
            break
            ;;
    esac
done

init_params $@

main
