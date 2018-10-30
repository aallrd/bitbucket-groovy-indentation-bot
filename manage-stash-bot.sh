#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

#~~~~~~~~~~~~~~~~~~~~~~ BOT CONFIGURATION ~~~~~~~~~~~~~~~~~~~~~~~
__bot_name="groovy-indentation-bot"
__jenkins_url="jenkins.company.com"
__jenkins_bot_job="groovy-indentation-bot"
#~~~~~~~~~~~~~~~~~~~ BITBUCKET CONFIGURATION ~~~~~~~~~~~~~~~~~~~~
__bitbucket_hostname="bitbucket.company.com"
__bitbucket_api_url="${__bitbucket_hostname}/rest/api/1.0"
__prnfb_api_url="${__bitbucket_hostname}/rest/prnfb-admin/1.0"
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function __usage_main() {
	__menu_lign
	__menu_header
	__menu_lign "[ OPTIONS ]"
	__menu_option "-h|--help" "Print this helper."
	__menu_lign "{ Settings }"
	__menu_option "-p|--project" "The name of the bitbucket project containing the repo to configure." "TEAM"
	__menu_option "-r|--repo" "The name of the bitbucket repo to configure with the bot." "my-repo"
	__menu_option "-u|--user" "The bitbucket username with the admin right on the repo to configure." "team-bitbucket-bot"
	__menu_lign "{ Actions }"
	__menu_option "--add" "Register the bot on the bitbucket repo."
	__menu_option "--delete" "Delete the bot from the bitbucket repo."
	__menu_lign
	__menu_footer
	__menu_lign
	return 0
}

function __parse_args() {
	local values mandatory_args actions
	mandatory_args=(__project __repo __user)
	actions=("--add" "--delete")
	for arg in "${@}" ; do
		case "${arg}" in
			-h|--help)
				__usage_main
				exit 0
				;;
			-p|--project)
				__project="${2:-}"
				shift 2
				;;
			-r|--repo)
				__repo="${2:-}"
				shift 2
				;;
			-u|--user)
				__user="${2:-}"
				shift 2
				;;
			--add)
				__action="ADD"
				;;
			--delete)
				__action="DELETE"
				;;
			*) __parsed_args+=("${arg}")
		esac
	done
	for arg in "${mandatory_args[@]}" ; do if [[ -z ${!arg+x} ]] ; then __perror "Mandatory option missing: [${arg}]" ; exit 1 ; fi ; done
	if [[ -z ${__action+x} ]] ; then __perror "Mandatory action missing: [$(IFS=$','; echo "${actions[*]}")]" ; exit 1; fi
	return 0
}

function __validate_requirements() {
	local requirements status
	status=0
	requirements=("curl" "base64" "grep")
	for requirement in "${requirements[@]}" ; do
		command -v "${requirement}" >/dev/null 2>&1 || {
			__perror "[${requirement}] is not available in the PATH."; status=1;
		}
	done
	return ${status}
}

function __validate_input() {
	local ret
	ret="$(curl -s -o /dev/null -w "%{http_code}" -X GET "http://${__bitbucket_api_url}/projects/${__project}")"
	if [[ "${ret}" != "200" ]]; then
		__perror "The project [${__project}] does not seem to exist on bitbucket."
		return 1
	fi
	__pinfo "Targeted bitbucket project: [${__project}]"
	ret="$(curl -s -o /dev/null -w "%{http_code}" -X GET "http://${__bitbucket_api_url}/projects/${__project}/repos/${__repo}")"
	if [[ "${ret}" != "200" ]]; then
		__perror "The repo [${__repo}] does not seem to exist on bitbucket."
		return 1
	fi
	__pinfo "Targeted bitbucket repo: [${__repo}]"
	ret="$(curl -s -o /dev/null -w "%{http_code}" -X GET "http://${__bitbucket_api_url}/users/${__user}")"
	if [[ "${ret}" != "200" ]]; then
		__perror "The user [${__user}] does not seem to exist on bitbucket."
		return 1
	fi
	return 0
}

function __validate_user_admin() {
	local ret
	__pinfo "Login on bitbucket as user [${__user}]..."
	__login || { echo "Failed to login user ${__user}."; return 1; }
	ret="$(curl -s -o /dev/null -w "%{http_code}" -X GET \
		"http://${__bitbucket_api_url}/projects/${__project}/repos/${__repo}/permissions/users" \
		-H "Authorization: Basic ${__http_basic_authorization}")"
	if [[ "${ret}" != "200" ]]; then
		__perror "The user [${__user}] is not admin on this repo: https://${__bitbucket_hostname}/projects/${__project}/repos/${__repo}"
		__pwarning "Please make sure that the user [${__user}] is configured with admin permission on the repo [${__repo}]: https://${__bitbucket_hostname}/projects/${__project}/repos/${__repo}/permissions"
		return 1
	fi
}

function __validate_bot_not_registered() {
	local bots_uuid
	# shellcheck disable=SC2207
	bots_uuid=($(__list_bots_uuid_matching_name))
	if [[ ${#bots_uuid[@]} -ne 0 ]] ; then
		__perror "The bot [${__bot_name}] is already registered on the repo [${__repo}]."
		__pwarning "You can use the --delete option to un-register it."
		return 1
	fi
	return 0
}

function __validate_bot_registered() {
	local bots_uuid
	# shellcheck disable=SC2207
	bots_uuid=($(__list_bots_uuid_matching_name))
	if [[ ${#bots_uuid[@]} -eq 0 ]] ; then
		__perror "The bot [${__bot_name}] is not registered on the repo [${__repo}]."
		return 1
	fi
	return 0
}

function __list_bots_uuid_matching_name() {
	local repo_bot_uuids repo_bot_name ret
	ret=()
	OLDIFS="${IFS}"
	IFS=$' \n\t'
	# shellcheck disable=SC2207
	repo_bot_uuids=($(curl -s -X GET \
		-H "Authorization: Basic ${__http_basic_authorization}" \
		-H 'Content-Type: application/json' \
		"http://${__prnfb_api_url}/settings/notifications/projectKey/${__project}/repositorySlug/${__repo}" \
		--stderr - | \grep -Po '"uuid":.*?[^\\]",' | tr -d '",' | awk -F':' '{print $2}' | xargs))
	if [[ ${#repo_bot_uuids[@]} -ne 0 ]] ; then
		for bot_uuid in ${repo_bot_uuids[*]}; do
			repo_bot_name=$(curl -s -X GET \
				-H "Authorization: Basic ${__http_basic_authorization}" \
				-H 'Content-Type: application/json' \
				"http://${__prnfb_api_url}/settings/notifications/${bot_uuid}" \
				--stderr - | \grep -Po '"name":.*?[^\\]",' | \grep -v 'Jenkins-Crumb' | tr -d ',' | awk -F':' '{print $2}' | xargs)
			if [[ "${repo_bot_name}" == "${__bot_name}" ]] ; then
				ret+=("${bot_uuid}")
			fi
		done
	fi
	IFS="${OLDIFS}"
	echo -n "${ret[*]}"
}

function __generate_prnfb_bot_post_data() {
	cat <<EOF
{
	"filterRegexp": "^(?!team-bitbucket-bot).*$",
	"filterString": "\${PULL_REQUEST_USER_SLUG}",
	"headers": [
		{
			"name": "Jenkins-Crumb",
			"value": "\${INJECTION_URL_VALUE}"
		}
	],
	"injectionUrl": "http://${__jenkins_url}/crumbIssuer/api/xml?xpath=//crumb",
	"injectionUrlRegexp": "<crumb>([^<]*)</crumb>",
	"method": "GET",
	"name": "${__bot_name}",
	"projectKey": "${__project}",
	"repositorySlug": "${__repo}",
	"triggerIfCanMerge": "ALWAYS",
	"triggerIgnoreStateList": [],
	"triggers": [
		"COMMENTED",
		"OPENED",
		"RESCOPED_FROM",
		"UPDATED"
	],
	"url": "http://${__jenkins_url}/job/${__jenkins_bot_job}/buildWithParameters?token=indentation-bot-token&\${EVERYTHING_URL}",
	"postContentEncoding": "NONE"
}
EOF
	return 0
}


function __register_bot() {
	local ret
	__pinfo "Registering [${__bot_name}] on the repo [${__repo}]..."
	ret="$(curl -s -o /dev/null -w "%{http_code}" -X POST \
		"http://${__prnfb_api_url}/settings/notifications" \
		-H "Authorization: Basic ${__http_basic_authorization}" \
		-H 'Content-Type: application/json' \
		--data "$(__generate_prnfb_bot_post_data)")"
	if [[ "${ret}" != "200" ]]; then
		__perror "Failed to register the bot [${__bot_name}] on the repo [${__repo}]."
		return 1
	else
		__psuccess "The bot [${__bot_name}] was successfully registered on the repo [${__repo}]."
		__pinfo "You can access the bot configuration from bitbucket: https://${__bitbucket_hostname}/plugins/servlet/prnfb/admin/${__project}/${__repo}"
	fi
	return 0
}

function __unregister_bot() {
	local ret bots_uuid status
	status=0
	# shellcheck disable=SC2207
	bots_uuid=($(__list_bots_uuid_matching_name))
	for bot_uuid in "${bots_uuid[@]}"; do
		ret="$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
			-H "Authorization: Basic ${__http_basic_authorization}" \
			"http://${__prnfb_api_url}/settings/notifications/${bot_uuid}")"
		if [[ "${ret}" == "200" ]]; then
			__psuccess "The bot [${__bot_name}] (${bot_uuid}) was un-registered on repo [${__repo}]."
		else
			__perror "Failed to un-register bot [${__bot_name}] (${bot_uuid}) on repo [${__repo}]."
			status=1
		fi
	done
	return ${status}
}

function __main() {
	__banner
	__parse_args "${@}"
	__validate_requirements || { return 1; }
	__validate_input || { return 1; }
	__validate_user_admin || { return 1; }
	if [[ ${__action} == "DELETE" ]] ; then
		__validate_bot_registered || { return 1; }
		__unregister_bot || { return 1; }
	elif [[ ${__action} == "ADD" ]] ; then
		__validate_bot_not_registered || { return 1; }
		__register_bot || { return 1; }
	else
		__perror "Unknown action: ${__action:?action is unset.}"
	fi
	return 0
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ UTILS ~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function __banner() {
	cat <<"EOF"
__________.__  __ ___.                  __           __    ___.           __
\______   \__|/  |\_ |__  __ __   ____ |  | __ _____/  |_  \_ |__   _____/  |_
 |    |  _/  \   __\ __ \|  |  \_/ ___\|  |/ // __ \   __\  | __ \ /  _ \   __\
 |    |   \  ||  | | \_\ \  |  /\  \___|    <\  ___/|  |    | \_\ (  <_> )  |
 |______  /__||__| |___  /____/  \___  >__|_ \\___  >__|    |___  /\____/|__|
        \/             \/            \/     \/    \/            \/
EOF
}

function __login() {
	local password
	echo -n "${__user}'s password: " ; read -rs password ; echo
	__http_basic_authorization=$(echo -n "${__user}:${password}" | base64)
	return 0
}

function __pinfo() {
	echo -e "\\e[34m[INFO] $(__pdate) ${1}\\e[0m"
	return 0
}

function __perror() {
	echo -e "\\e[31m[ERROR] $(__pdate) ${1}\\e[0m" >&2
	return 0
}

function __pwarning() {
	echo -e "\\e[33m[WARNING] $(__pdate) ${1}\\e[0m"
	return 0
}

function __psuccess() {
	echo -e "\\e[32m[SUCCESS] $(__pdate) ${1}\\e[0m"
	return 0
}

function __pdate() {
	echo -n "[$(date +%H:%M:%S)]"
	return 0
}

function __menu_lign() {
	local line msg length sep msg_offset
	msg=${1:-}
	msg_offset=5
	length=${2:-75}
	sep=${3:--}
	line="$(printf "%*s" "${length}")" && echo -en "\\e[34m${line// /${sep}}\\e[0m"
	if [[ ! -z ${msg+x} ]]; then
		echo -e "\\r\\033[${msg_offset}C\\e[1;34m${msg}\\e[0m"
	fi
	return 0
}

function __menu_header() {
	printf "\\e[1;34mUsage: %s [OPTIONS]\\e[0m\\n" "${0##*/}"
	return 0
}

function __menu_option() {
	local padding sep option helper values
	padding="$(printf "%*s" 10)"
	sep=" : "
	option="${1:-}" ; helper="${2:-}" ; values="${3:-}"
	printf "${padding}\\e[1m%-20s${sep}\\e[0m%-50s\\n" "${option}" "${helper}"
	if [[ ! -z ${values+x} && ${values} != "" ]]; then
		printf "${padding}%-$((20 + ${#sep}))sExample: \\e[1m%-30s\\e[0m\\n" "" "${values}"
	fi
	return 0
}

function __menu_table_row() {
	local header col1
	header="${1:-}" ; col1="${2:-}"
	printf "\\e[1m%-10s:\\e[0m %-30s\\n" "${header}" "${col1}"
	return 0
}

function __menu_footer() {
	printf "\\e[1;32m%s\\e[0m\\n" "Report bugs to github.com/aallrd/bitbucket-groovy-indentation-bot"
	return 0
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

__main "${@}"
