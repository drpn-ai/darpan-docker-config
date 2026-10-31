# DAR-BE-169 lab. The root pod: today's image with an unreleased darpan jar laid over it (ScriptSupervisor dispatches
# to the worker when DARPAN_SCRIPT_WORKER_URL is set). Lab only: a release builds the jar from a tagged darpan ref.
#   docker build -f k8s-lab/root.Dockerfile -t darpan-root:lab <context holding darpan-2.1.5-lab.jar>
FROM darpan:uat
COPY darpan-2.1.5-lab.jar /moqui-deploy/WEB-INF/lib/darpan-2.1.5.jar
COPY darpan-2.1.5-lab.jar /moqui-framework/runtime/component/darpan/lib/darpan-2.1.5.jar
