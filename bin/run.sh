#!/usr/bin/env bash

INSTALL_DIR_TEMP="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"

function dr-update-env {

  if [[ -f "$DIR/system.env" ]]
  then
    LINES=$(grep -v '^#' $DIR/system.env)
    for l in $LINES; do
      env_var=$(echo $l | cut -f1 -d\=)
      env_val=$(echo $l | cut -f2 -d\=)
      eval "export $env_var=$env_val"
    done
  else
    echo "File system.env does not exist."
    return 1
  fi

  if [[ -f "$DR_CONFIG" ]]
  then
    LINES=$(grep -v '^#' $DR_CONFIG)
    for l in $LINES; do
      env_var=$(echo $l | cut -f1 -d\=)
      env_val=$(echo $l | cut -f2 -d\=)
      eval "export $env_var=$env_val"
    done
  else
    echo "File run.env does not exist."
    return 1
  fi

  if [[ -z "${DR_RUN_ID}" ]]; then
    export DR_RUN_ID=0
  fi

  if [[ "${DR_DOCKER_STYLE,,}" == "swarm" ]];
  then
    export DR_ROBOMAKER_TRAIN_PORT=$(expr 8080 + $DR_RUN_ID)
    export DR_ROBOMAKER_EVAL_PORT=$(expr 8180 + $DR_RUN_ID)
    export DR_ROBOMAKER_GUI_PORT=$(expr 5900 + $DR_RUN_ID)
  else
    export DR_ROBOMAKER_TRAIN_PORT="8080-8089"
    export DR_ROBOMAKER_EVAL_PORT="8080-8089"
    export DR_ROBOMAKER_GUI_PORT="5901-5920"
  fi

}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DIR="$( dirname $SCRIPT_DIR )"
export DR_DIR=$DIR

if [[ -f "$1" ]];
then
  export DR_CONFIG=$(readlink -f $1)
  dr-update-env
elif [[ -f "$DIR/run.env" ]];
then
  export DR_CONFIG="$DIR/run.env"
  dr-update-env
else
  echo "No configuration file."
  return 1
fi

sudo -s source $INSTALL_DIR_TEMP/bin/activate.sh

# Check if Docker runs -- if not, then start it.
if [[ "$(type service 2> /dev/null)" ]]; then
  service docker status > /dev/null || sudo service docker start
fi

# Check if we will use Docker Swarm or Docker Compose
# If not defined then use Swarm
if [[ -z "${DR_DOCKER_STYLE}" ]]; then
  export DR_DOCKER_STYLE="swarm"
fi

if [[ "${DR_DOCKER_STYLE,,}" == "swarm" ]];
then
  export DR_DOCKER_FILE_SEP="-c"
  SWARM_NODE=$(docker node inspect self | jq .[0].ID -r)
  SWARM_NODE_UPDATE=$(docker node update --label-add Sagemaker=true $SWARM_NODE)
else
  export DR_DOCKER_FILE_SEP="-f"
fi

# Prepare the docker compose files depending on parameters
if [[ "${DR_CLOUD,,}" == "azure" ]];
then
    export DR_LOCAL_S3_ENDPOINT_URL="http://localhost:9000"
    export DR_MINIO_URL="http://minio:9000"
    DR_LOCAL_PROFILE_ENDPOINT_URL="--profile $DR_LOCAL_S3_PROFILE --endpoint-url $DR_LOCAL_S3_ENDPOINT_URL"
    DR_TRAIN_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-training.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_EVAL_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-eval.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_MINIO_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-azure.yml"
elif [[ "${DR_CLOUD,,}" == "local" ]];
then
    export DR_LOCAL_S3_ENDPOINT_URL="http://localhost:9000"
    export DR_MINIO_URL="http://minio:9000"
    DR_LOCAL_PROFILE_ENDPOINT_URL="--profile $DR_LOCAL_S3_PROFILE --endpoint-url $DR_LOCAL_S3_ENDPOINT_URL"
    DR_TRAIN_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-training.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_EVAL_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-eval.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_MINIO_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-local.yml"
elif [[ "${DR_CLOUD,,}" == "remote" ]];
then
    export DR_LOCAL_S3_ENDPOINT_URL="$DR_REMOTE_MINIO_URL"
    export DR_MINIO_URL="$DR_REMOTE_MINIO_URL"
    DR_LOCAL_PROFILE_ENDPOINT_URL="--profile $DR_LOCAL_S3_PROFILE --endpoint-url $DR_LOCAL_S3_ENDPOINT_URL"
    DR_TRAIN_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-training.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_EVAL_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-eval.yml $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-endpoint.yml"
    DR_MINIO_COMPOSE_FILE=""
else
    DR_LOCAL_PROFILE_ENDPOINT_URL=""
    DR_TRAIN_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-training.yml"
    DR_EVAL_COMPOSE_FILE="$DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-eval.yml"
fi

# Prevent docker swarms to restart
if [[ "${DR_HOST_X,,}" == "true" ]];
then
    DR_TRAIN_COMPOSE_FILE="$DR_TRAIN_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-local-xorg.yml"
    DR_EVAL_COMPOSE_FILE="$DR_EVAL_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-local-xorg.yml"
fi

# Prevent docker swarms to restart
if [[ "${DR_DOCKER_STYLE,,}" == "swarm" ]];
then
    DR_TRAIN_COMPOSE_FILE="$DR_TRAIN_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-training-swarm.yml"
    DR_EVAL_COMPOSE_FILE="$DR_EVAL_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-eval-swarm.yml"
fi

# Enable logs in CloudWatch
if [[ "${DR_CLOUD_WATCH_ENABLE,,}" == "true" ]]; then
    DR_TRAIN_COMPOSE_FILE="$DR_TRAIN_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-cwlog.yml"
    DR_EVAL_COMPOSE_FILE="$DR_EVAL_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-cwlog.yml"
fi

## Check if we have an AWS IAM assumed role, or if we need to set specific credentials.
if [ "${DR_CLOUD,,}" == "aws" ] && [ $(aws --output json sts get-caller-identity 2> /dev/null | jq '.Arn' | awk /assumed-role/ | wc -l ) -gt 0 ];
then
    export DR_LOCAL_S3_AUTH_MODE="role"
else 
    export DR_LOCAL_ACCESS_KEY_ID=$(aws --profile $DR_LOCAL_S3_PROFILE configure get aws_access_key_id | xargs)
    export DR_LOCAL_SECRET_ACCESS_KEY=$(aws --profile $DR_LOCAL_S3_PROFILE configure get aws_secret_access_key | xargs)
    DR_TRAIN_COMPOSE_FILE="$DR_TRAIN_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-keys.yml"
    DR_EVAL_COMPOSE_FILE="$DR_EVAL_COMPOSE_FILE $DR_DOCKER_FILE_SEP $DIR/docker/docker-compose-keys.yml"
    export DR_UPLOAD_PROFILE="--profile $DR_UPLOAD_S3_PROFILE"
    export DR_LOCAL_S3_AUTH_MODE="profile"
fi

export DR_TRAIN_COMPOSE_FILE
export DR_EVAL_COMPOSE_FILE
export DR_LOCAL_PROFILE_ENDPOINT_URL

source $INSTALL_DIR_TEMP/bin/scripts_wrapper.sh

