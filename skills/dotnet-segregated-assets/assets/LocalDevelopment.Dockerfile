FROM dhi.io/aspnetcore:{DotNetMajor}-alpine{AlpineVersion}-dev

WORKDIR /app

COPY --chown=65532:65532 artifacts/publish/ .

USER 65532

EXPOSE 8080

ENTRYPOINT ["dotnet", "{ProjectName}.dll"]
