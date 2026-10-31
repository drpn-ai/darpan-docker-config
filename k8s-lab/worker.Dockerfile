# DAR-BE-169 lab. The script worker: Temurin 21 JRE + the darpan.script package and the five jars it loads (Groovy,
# groovy-json, commons-jexl3, slf4j-api, and commons-logging, which JEXL logs through; Moqui supplies it in the root
# pod). No Moqui, no connectors, no credentials. Build context = a folder holding
# darpan-script-engine.jar (only darpan/script/** from the darpan jar):
#   docker build -f k8s-lab/worker.Dockerfile -t darpan-script-worker:lab <context>
FROM darpan:uat AS darpan

FROM eclipse-temurin:21-jre
COPY --from=darpan /moqui-deploy/WEB-INF/lib/groovy-5.0.3.jar \
                   /moqui-deploy/WEB-INF/lib/groovy-json-5.0.3.jar \
                   /moqui-deploy/WEB-INF/lib/commons-jexl3-3.7.1.jar \
                   /moqui-deploy/WEB-INF/lib/slf4j-api-2.0.17.jar \
                   /moqui-deploy/WEB-INF/lib/commons-logging-1.3.5.jar /app/lib/
COPY darpan-script-engine.jar /app/lib/
USER 10001:10001
EXPOSE 8090
# ExitOnOutOfMemoryError: a script that exhausts the heap ends this process, and Kubernetes starts a clean one.
# -UsePerfData: no hsperfdata writes, so the root filesystem can be read-only.
ENTRYPOINT ["java", "-XX:+ExitOnOutOfMemoryError", "-XX:-UsePerfData", "-XX:MaxRAMPercentage=70", \
            "-cp", "/app/lib/*", "darpan.script.ScriptWorker"]
