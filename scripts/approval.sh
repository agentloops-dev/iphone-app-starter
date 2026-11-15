#!/bin/bash
# A deploy that waits for an approval in Agent Loops, on any GitHub plan (GitHub Free has an
# environment's required reviewers on public repositories only). Each step uses the GitHub
# Deployments API with the workflow's GITHUB_TOKEN (permission deployments: write).
#
#   approval.sh ask <environment> <workflow>   on a tag: make a Deployment of the task
#                                              deploy:approval, status pending; Approve in
#                                              Agent Loops starts <workflow> on the tag with it
#   approval.sh start <environment>            in <workflow>: fail unless inputs.deployment
#                                              ($DEPLOYMENT) is approved (status queued) for
#                                              this commit and environment; then in_progress
#   approval.sh end <job status>               in <workflow>, if: always(): success or failure
set -euo pipefail
api() { gh api "repos/$GITHUB_REPOSITORY/$1" "${@:2}"; }
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

case "${1:-}" in
ask)
	environment=${2:?environment} workflow=${3:?workflow}
	id=$(jq -n --arg ref "$GITHUB_REF_NAME" --arg environment "$environment" --arg workflow "$workflow" \
		--arg actor "${GITHUB_TRIGGERING_ACTOR:-$GITHUB_ACTOR}" '{ref: $ref, environment: $environment,
		task: "deploy:approval", auto_merge: false, required_contexts: [], production_environment: true,
		description: "Waits for an approval in Agent Loops", payload: {workflow: $workflow, actor: $actor}}' |
		api deployments --input - --jq .id)
	api "deployments/$id/statuses" -f state=pending -f log_url="$run_url" \
		-f description="Waits for an approval in Agent Loops" > /dev/null
	echo "::notice::$GITHUB_REF_NAME waits for an approval in Agent Loops (Needs You) to $environment: Deployment $id."
	;;
start)
	environment=${2:?environment}
	if [[ ! ${DEPLOYMENT:-} =~ ^[0-9]+$ ]]; then
		echo "::error::deployment is a GitHub Deployment's id. Nothing was shipped."
		exit 1
	fi
	read -r task sha env < <(api "deployments/$DEPLOYMENT" --jq '"\(.task) \(.sha) \(.environment)"')
	state=$(api "deployments/$DEPLOYMENT/statuses?per_page=1" --jq '.[0].state // ""')
	if [[ $task != deploy:approval || $sha != "$GITHUB_SHA" || $env != "$environment" || $state != queued ]]; then
		echo "::error::Deployment $DEPLOYMENT is not one approved in Agent Loops for this commit and $environment. Nothing was shipped."
		exit 1
	fi
	echo "DEPLOYMENT_APPROVED=$DEPLOYMENT" >> "$GITHUB_ENV"
	api "deployments/$DEPLOYMENT/statuses" -f state=in_progress -f log_url="${JOB_URL:-$run_url}" > /dev/null
	;;
end)
	[[ -n ${DEPLOYMENT_APPROVED:-} ]] || exit 0
	state=failure
	[[ ${2:-} == success ]] && state=success
	api "deployments/$DEPLOYMENT_APPROVED/statuses" -f state="$state" -f log_url="${JOB_URL:-$run_url}" > /dev/null
	;;
*)
	echo "usage: approval.sh ask <environment> <workflow> | start <environment> | end <job status>" >&2
	exit 2
	;;
esac
