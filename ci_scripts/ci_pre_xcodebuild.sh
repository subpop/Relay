#!/bin/zsh

set -e

cp "${CI_PRIMARY_REPOSITORY_PATH}/Secrets.xcconfig.example ${CI_PRIMARY_REPOSITORY_PATH}/Secrets.xcconfig"
sed -i -e "s/your_team_id_here/${CI_TEAM_ID}/" "${CI_PRIMARY_REPOSITORY_PATH}/Secrets.xcconfig"
sed -i -e "s/your_giphy_api_key_here/${GIPHY_API_KEY}/" "${CI_PRIMARY_REPOSITORY_PATH}/Secrets.xcconfig"
