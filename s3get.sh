#!/bin/sh

VERSION=0.0.9
VERBOSE=0

v_msg() {
    if [ $VERBOSE -gt 0 ]; then
        echo "$@" 1>&2
    fi
}
usage_exit() {
    cat <<EOF
Usage: $0 [--profile XXX] [--access-key ID] [--secret-key SECRET_KEY] [--help] OBJECT_PATH OUTPUT_PATH
  -p|--proflie        : credential profile. default= "default"
  -r|--region         : aws region. default= "us-east-1"
  -a|--access-key     : aws access key
  -s|--secret-key     : aws secret key
  -c|--credential-url : full url for credentiall json

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
  s3get.sh https://s3-ap-northeast-1.amazonaws.com/BUCKET_NAME/path/to/object ./save_object
    load credentials from ~/.aws/credentials ( "default" profile ) or instance meta-data
    download object to ./save_object
  s3get.sh -a HOGEHOGE -s MOGEMOGE s3://bucket/path/to/object /path/to/save/object
    use credentials, AccessKey=HOGEHOGE SecretKey=MOGEMOGE
    load region from ~/.aws/config ( "default" profile ) or instance meta-data
    download from /bucket/path/to/object to /path/to/object
  s3get.sh s3://bucket/path/to/dir/ ./dest/
    recursive get to ./dest/dir/
EOF
    exit 1
}

get_credential_from_meta() {
    if [ -n "${CREDENTIAL_URL}" ]; then
        v_msg "get credential from url : $CREDENTIAL_URL"
        IAM_JUSON=$(curl -L $CREDENTIAL_URL --silent)
    elif [ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}" ]; then
        local _META_URL="http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}"
        v_msg "get credential from task role : $_META_URL"
        IAM_JSON=$(curl  -L $_META_URL --silent)
    else
        local _ROLE_URL="http://169.254.169.254/latest/meta-data/iam/security-credentials/"
        v_msg "get role name from instance metadata : $_ROLE_URL"
        ROLE_NAME=$(curl -L $_ROLE_URL --silent --connect-timeout 3 | grep '^[a-zA-Z0-9._-]\+$') && {
            local _META_URL="http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE_NAME}"
            v_msg "get credential from metadata : $_META_URL"
            IAM_JSON=$(curl  -L $_META_URL --silent)
        }
    fi
}

get_region_from_meta() {
    v_msg "get region from instance metadata"
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
            ACCESS_KEY=$(cat ~/.aws/credentials  | grep -E '^(\[|aws_access_key_id|aws_secret_access_key)' | grep "\[${PROFILE}\]" -A 2 | grep "^aws_access_key_id" | sed -e 's/=/ /' | awk '{print $2}')
            SECRET_KEY=$(cat ~/.aws/credentials  | grep -E '^(\[|aws_access_key_id|aws_secret_access_key)' | grep "\[${PROFILE}\]" -A 2 | grep "^aws_secret_access_key" | sed -e 's/=/ /' | awk '{print $2}')
        elif get_credential_from_meta; then
            ACCESS_KEY=$(/bin/echo "$IAM_JSON" | sed -r 's!.*"AccessKeyId"\s*:\s*"([^"]+).*!\1!')
            SECRET_KEY=$(/bin/echo "$IAM_JSON" | sed -r 's!.*"SecretAccessKey"\s*:\s*"([^"]+).*!\1!')
            TOKEN=$(/bin/echo "$IAM_JSON" | sed -r 's!.*"Token"\s*:\s*"([^"]+).*!\1!')
        else
            err_exit "can not found ~/.aws/credentials"
        fi
    fi
    if [ -z "$ACCESS_KEY" -o -z "$SECRET_KEY" ]; then
        err_exit "credentials is not defined"
    fi

    if [ -n "$SRC" ]; then
        if /bin/echo "$SRC" | grep "^s3://" > /dev/null; then
            BUCKET=$(/bin/echo "$SRC" | sed 's!^s3://\([^/]\+\)/.\+$!\1!')
            SRC_PATH=$(/bin/echo "$SRC" | sed 's!^s3://[^/]\+\(/.\+\)$!\1!')
        elif /bin/echo "$SRC" | grep "^https\?://" > /dev/null; then
            if /bin/echo "$SRC" | grep "^https\?://s3-[^.]\+\.amazonaws\.com/" > /dev/null; then
                S3_HOST=$(/bin/echo "$SRC" | sed 's!^https\?://\([^/]\+\)/.\+$!\1!')
                REGION=$(/bin/echo "$SRC" | sed 's!^https\?://s3-\([^.]\+\)\.amazonaws\.com/.\+$!\1!')
                BUCKET=$(/bin/echo "$SRC" | sed 's!^https\?://[^/]\+/\([^/]\+\)/.\+$!\1!')
                SRC_PATH=$(/bin/echo "$SRC" | sed 's!^https\?://[^/]\+/[^/]\+\(/.\+\)$!\1!')
            elif /bin/echo "$SRC" | grep "^https\?://.\+\.s3-[^.]\+\.amazonaws\.com" > /dev/null; then
                S3_HOST=$(/bin/echo "$SRC" | sed 's!^https\?://\([^/]\+\)/.\+$!\1!')
                BUCKET=$(/bin/echo "$SRC" | sed 's!^https\?://\(.\+\)\.s3-[^.]\+\.amazonaws\.com/.\+$!\1!')
                REGION=$(/bin/echo "$SRC" | sed 's!^https\?://.\+\.s3-\([^.]\+\)\.amazonaws\.com/.\+$!\1!')
                SRC_PATH=$(/bin/echo "$SRC" | sed 's!^https\?://[^/]\+\(/.\+\)$!\1!')
            else
                S3_HOST=$(/bin/echo "$SRC" | sed 's!^https\?://\([^/]\+\)/.\+$!\1!')
                BUCKET=$(/bin/echo "$SRC" | sed 's!^https\?://[^/]\+/\([^/]\+\)/.\+$!\1!')
                SRC_PATH=$(/bin/echo "$SRC" | sed 's!^https\?://[^/]\+/[^/]\+\(/.\+\)$!\1!')
            fi
        fi
    fi
    if [ -z "$REGION" ]; then
        if [ -f ~/.aws/config ]; then
            PKEY=$PROFILE
            if [ "$PKEY" != "default" ]; then
                PKEY="profile $PKEY"
            fi
            REGION=$(cat ~/.aws/config | grep -E '^(\[|region)' | grep "\[$PKEY\]" -A 1 | grep "^region" | sed -e 's/=/ /' | awk '{print $2}')
        elif get_region_from_meta; then
            REGION=$META_REGION
        fi
        if [ -z "$REGION" ]; then
            REGION=us-east-1
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
    /bin/echo "$@" >&2
    exit 1
}

list_object() {
    PREFIX=$(/bin/echo "$SRC_PATH" | sed 's!^/!!')
    v_msg "list object: $BUCKET / $PREFIX"
    call_api "GET" "/${BUCKET}" "?list-type=2&prefix=$PREFIX" | grep -o "<Key[^>]*>[^<]*</Key>" | sed -e "s/<Key>\(.*\)<\/Key>/\1/" | grep -v -E '/$'
}

get_object() {
    OBJ_PATH=$1
    OUT_PATH=$2

    v_msg "get object: /$BUCKET/$OBJ_PATH -> $OUT_PATH"
    CHECK_RSLT=$(call_api "HEAD" "/${BUCKET}$OBJ_PATH")

    if /bin/echo "$CHECK_RSLT" | grep "200 OK" > /dev/null; then
        if [ "$OUT_PATH" = "-" ]; then
            call_api "GET" "/${BUCKET}$OBJ_PATH"
        else
            mkdir -p $(dirname $OUT_PATH)
            call_api "GET" "/${BUCKET}$OBJ_PATH" > $OUT_PATH
        fi
    else
        err_exit "can not get object $OBJ_PATH $(/bin/echo "$CHECK_RSLT" | head -n 1 )"
    fi
}
call_api() {
    METHOD=$1
    RESOURCE=$2
    QUERY=$3
    
    DATE_VALUE=$(LC_ALL=C date +'%a, %d %b %Y %H:%M:%S %z')

    CURL_OPT=""
    if [ "$METHOD" = "HEAD" ]; then
        CURL_OPT="-I"
    fi
    STR2SIGN="$METHOD


$DATE_VALUE"
    if [ -n "$TOKEN" ]; then
        STR2SIGN="$STR2SIGN
x-amz-security-token:$TOKEN"
    fi
    STR2SIGN="$STR2SIGN
$RESOURCE"
    SIGNATURE=$(/bin/echo -en "$STR2SIGN" | openssl sha1 -hmac ${SECRET_KEY} -binary | base64)
    if [ -n "$TOKEN" ]; then
        curl -H "Host: ${S3_HOST}" \
             -H "Date: ${DATE_VALUE}" \
             -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE}" \
             -H "x-amz-security-token: $TOKEN" \
             --silent \
             $CURL_OPT \
             https://${S3_HOST}${RESOURCE}${QUERY}
    else
        curl -H "Host: ${S3_HOST}" \
             -H "Date: ${DATE_VALUE}" \
             -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE}" \
             --silent \
             $CURL_OPT \
             https://${S3_HOST}${RESOURCE}${QUERY}
    fi
}

main() {
    if /bin/echo "$SRC_PATH" | grep -e '/$' > /dev/null; then
        if [ "$DST_PATH" = "-" ]; then
            /bin/echo "if get recursive, please set directory path to dest"
            exit 1
        fi
        list_object | while read LINE; do
            DST_LINE=$(/bin/echo "/$LINE" | sed -e "s!$SRC_PATH!!")
            get_object /$LINE $DST_PATH/$DST_LINE
        done
    else
        if /bin/echo "$DST_PATH" | grep -e "/$" > /dev/null; then
            DST_PATH="$DST_PATH/$(basename $SRC_PATH)"
        fi
        get_object $SRC_PATH $DST_PATH
    fi
}


PROFILE=""
ACCESS_KEY=""
SECRET_KEY=""
CREDENTIAL_URL=""
S3_HOST=""
REGION=""
SRC_PATH=""
DST_PATH=""

OPT=$(getopt -o p:r:a:s:c:Vvh --long profile:,region:,access-key:,secret-key:,credential-url:,verbose,version,help -- "$@")
if [ $? != 0 ]; then
    /bin/echo "$OPT"
    exit 1
fi
eval set -- "$OPT"

for x in "$@"; do
    case "$1" in
        -h | --help)
            usage_exit
            ;;
        -v | --version)
            /bin/echo "s3get.sh version ${VERSION}"
            exit
            ;;
        -V | --verbose)
            VERBOSE=1
            shift 1
            ;;
        -p | --profile)
            PROFILE=$2
            shift 2
            ;;
        -r | --region)
            REGION=$2
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
        -c | --credential-url)
            CREDENTIAL_URL=$2
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
