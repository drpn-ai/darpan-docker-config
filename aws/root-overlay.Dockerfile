# DAR-BE-169 AWS UAT root image: today's UAT image (darpan:uat) with only the script-worker pieces laid over it, so no
# other unreleased darpan code rides along. Context = a folder holding
#   darpan-2.1.5-lab.jar      UAT's own darpan jar with the darpan/script package swapped in (DAR-BE-169/175 classes)
#   screen/Settings.xml       + the Script Worker menu line
#   screen/Settings/ScriptWorker.xml, screen/Settings/ScriptLab.xml
#   service/facade/TenantScriptFacadeServices.xml   (DAR-BE-175: ScriptChecker on save, allow-html="any" for script text)
#   docker build --platform linux/arm64 -f aws/root-overlay.Dockerfile -t <ecr>/darpan-uat/darpan:uat-worker4 <context>
# The LIVE Moqui runtime is /moqui-deploy/runtime (/moqui-framework/runtime is only the build tree; screens copied there
# are never read, which is how uat-worker3 answered 404). The only darpan jar Moqui loads is WEB-INF/lib's: the live
# runtime's component/darpan/lib holds none. A release builds all of this from a tagged darpan ref instead.
FROM darpan:uat
COPY darpan-2.1.5-lab.jar /moqui-deploy/WEB-INF/lib/darpan-2.1.5.jar
COPY screen/Settings.xml /moqui-deploy/runtime/component/darpan/screen/Settings.xml
COPY screen/Settings/ScriptWorker.xml /moqui-deploy/runtime/component/darpan/screen/Settings/ScriptWorker.xml
COPY screen/Settings/ScriptLab.xml /moqui-deploy/runtime/component/darpan/screen/Settings/ScriptLab.xml
COPY service/facade/TenantScriptFacadeServices.xml /moqui-deploy/runtime/component/darpan/service/facade/TenantScriptFacadeServices.xml
