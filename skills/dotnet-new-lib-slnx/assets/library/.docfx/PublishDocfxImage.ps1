$version = minver -i -t v -v w
docker tag {REPO_SLUG}-docs:$version your-registry/{REPO_SLUG}-docs:$version
docker push your-registry/{REPO_SLUG}-docs:$version
