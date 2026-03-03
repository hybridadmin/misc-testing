#!/bin/bash
source /etc/profile.d/awsvars.sh
AWS_USER_KEY_BUCKET=moya-internal

export AWS_ACCESS_KEY_ID=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_access_key_id" |sed 's/aws_access_key_id = //')
export AWS_SECRET_ACCESS_KEY=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_secret_access_key" |sed 's/aws_secret_access_key = //')
export AWS_SESSION_TOKEN=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_session_token" |sed 's/aws_session_token = //')

remove_user(){
    user=$1
    echo "Removing user ${user}"
    /usr/sbin/userdel -r ${user}
}

create_user(){
    user=$1
    if [ ! -d "/home/${user}" ]; then
        echo "Creating user ${user}"
        /usr/sbin/useradd -m -d /home/${user} -s /bin/bash ${user}
        mkdir /home/${user}/.ssh; chown ${user}:${user} /home/${user}/.ssh; chmod 700 /home/${user}/.ssh
    else
        echo "Updating user ${user}"
    fi
    aws s3 cp --region eu-west-1 s3://${AWS_USER_KEY_BUCKET}/authorized_users/${user} /home/${user}/.ssh/authorized_keys
    chown ${user}:${user} -R /home/${user}/.ssh; chmod 600 /home/${user}/.ssh/authorized_keys
    usermod -aG sudo ${user}
    aws s3 cp --region eu-west-1 s3://${AWS_USER_KEY_BUCKET}/authorized_users/${user}.tgz /home/${user}/ 2> /dev/null
    if [ -f /home/${user}/${user}.tgz ]; then
        tar -xzf /home/${user}/${user}.tgz -C /home/${user}
        chown ${user}: -R /home/${user}
        if [ -f /home/${user}/setupuser.sh ]; then
            su - ${user} -c /home/${user}/setupuser.sh
        fi
    fi
    # Add user to sudoers
    # Fix - https://stackoverflow.com/a/21640893
    user_filename=$(echo $user| tr '.' '_')
    echo "${user}   ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/$user_filename

    # hushlogin - disable login banner
    touch /home/$user/.hushlogin
    chown ${user}:${user} /home/$user/.hushlogin
}

# Get list of authorised users
rm -fr /tmp/keys
mkdir /tmp/keys
list_name=${AWS_PROJECT,,}_${AWS_ENVIRONMENT,,}.lst
aws s3 cp --region eu-west-1 s3://${AWS_USER_KEY_BUCKET}/authorized_users/access_lists/${list_name} /tmp/keys/
aws s3 cp --region eu-west-1 s3://${AWS_USER_KEY_BUCKET}/authorized_users/access_lists/secops.lst /tmp/keys/

# Create list of users
users_lists="$(cat /tmp/keys/${list_name}), $(cat /tmp/keys/secops.lst)"

# Remove duplicate users
users_lists=$(echo ${users_lists} | tr ', ' '\n' | sort | uniq | tr '\n' ',' | sed -e 's/[[:space:]]*$//')

IFS=',' read -r -a authorized_users <<< ${users_lists}

is_authorized_user () {
    for authorized_user in "${authorized_users[@]}"
    do
        if [ "${authorized_user}" == "$1" ]; then
            return 0
        fi
    done
    return 1
}

# Remove existing users
for directory in /home/*; do
    user=${directory#/home/}
    is_authorized_user "${user}" && continue
    if [ "${user}" == "lambda" ]; then continue; fi
    if [ "${user}" == "moya" ]; then continue; fi
    if [ "${user}" == "ssm-user" ]; then continue; fi
    if [ "${user}" == "binu" ]; then continue; fi
    if [ "${user}" == "rdsuser" ]; then continue; fi
    if [ "${user}" == "builduser" ]; then continue; fi
    if [ "${user}" == "moyaadmin" ]; then continue; fi
    if [ "${user}" == "ejabberd" ]; then continue; fi
    if [ "${user}" == "postgres" ]; then continue; fi
    if [ "${user}" == "keepalived_script" ]; then continue; fi
    remove_user ${user}
done

# Create authorized users
for authorized_user in "${authorized_users[@]}"
do
    if [[ ! -z "${authorized_user}" ]]; then
        create_user ${authorized_user}
    fi
done
