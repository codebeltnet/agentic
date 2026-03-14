$version = minver -i -t v -v w
docfx metadata docfx.json
docker buildx build -t {REPO_SLUG}-docs:$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .
Get-ChildItem -Recurse -Path api -Include *.yml, .manifest | Remove-Item
