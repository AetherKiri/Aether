FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY java/build.sh ./build.sh
COPY java/src/ ./src/
RUN sh ./build.sh

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /src/build/validator.jar ./
COPY --from=build /src/build/lib/*.jar ./lib/
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-Xmx96m", "-cp", "validator.jar:lib/*", "aether.telemetry.ValidatorServer"]
