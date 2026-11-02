# AWS UAT image for tenant scripts (DAR-BE-175): today's UAT image (darpan:uat) with only the script pieces laid over
# it, so no other unreleased darpan code rides along. Context = a folder holding
#   darpan-2.1.5-lab.jar      UAT's own darpan jar with darpan/script/* and darpan/admin/SystemLoadReader* swapped in
#                             (ScriptLoadGate calls SystemLoadReader.processCpuPercent, private in older jars)
#   service/facade/TenantScriptFacadeServices.xml   (trial run on save, allow-html="any" for script text)
#   docker build --platform linux/arm64 -f aws/root-overlay.Dockerfile -t <ecr>/darpan-uat/darpan:uat-scripts1 <context>
# NOTE: the live Moqui runtime is /moqui-deploy/runtime and the only darpan jar Moqui loads is WEB-INF/lib's
FROM darpan:uat
COPY darpan-2.1.5-lab.jar /moqui-deploy/WEB-INF/lib/darpan-2.1.5.jar
COPY service/facade/TenantScriptFacadeServices.xml /moqui-deploy/runtime/component/darpan/service/facade/TenantScriptFacadeServices.xml
