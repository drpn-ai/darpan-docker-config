-- Run on UAT's database right after it is restored from a prod snapshot (DAR-OPS-027), before the app starts.
-- UAT keeps prod's data and client credentials, but must never reach a client or Darpan's real alerts room:
-- no chat posts (Google Chat / Slack webhooks, Slack bot), no email (no SMTP host), no alerts-room posts.
-- Idempotent. The scheduler is off separately (SchedulerEnabled=false -> scheduled_job_check_time=0).

UPDATE TENANT_CHAT_SPACE SET WEBHOOK_URL = NULL, GOOGLE_CHAT_WEBHOOK_URL = NULL;
UPDATE TENANT_NOTIFICATION_SETTING SET GOOGLE_CHAT_WEBHOOK_URL = NULL;
UPDATE SLACK_WORKSPACE_INSTALL SET BOT_ACCESS_TOKEN = NULL;
DELETE FROM DARPAN_SETTING WHERE SETTING_KEY = 'errors.chat.webhookUrl';
-- No SMTP host (no send), no inbound mailbox poll, and prod's mailbox app password does not live in UAT.
UPDATE EMAIL_SERVER SET SMTP_HOST = NULL, STORE_HOST = NULL, MAIL_PASSWORD = NULL;

-- Read-back: every count must be 0.
SELECT 'chat webhooks' AS what, COUNT(*) AS n FROM TENANT_CHAT_SPACE WHERE WEBHOOK_URL IS NOT NULL OR GOOGLE_CHAT_WEBHOOK_URL IS NOT NULL
UNION ALL SELECT 'legacy webhooks', COUNT(*) FROM TENANT_NOTIFICATION_SETTING WHERE GOOGLE_CHAT_WEBHOOK_URL IS NOT NULL
UNION ALL SELECT 'slack bot tokens', COUNT(*) FROM SLACK_WORKSPACE_INSTALL WHERE BOT_ACCESS_TOKEN IS NOT NULL
UNION ALL SELECT 'alerts-room setting', COUNT(*) FROM DARPAN_SETTING WHERE SETTING_KEY = 'errors.chat.webhookUrl'
UNION ALL SELECT 'smtp hosts', COUNT(*) FROM EMAIL_SERVER WHERE SMTP_HOST IS NOT NULL AND SMTP_HOST <> ''
UNION ALL SELECT 'mailbox passwords', COUNT(*) FROM EMAIL_SERVER WHERE MAIL_PASSWORD IS NOT NULL OR STORE_HOST IS NOT NULL;
