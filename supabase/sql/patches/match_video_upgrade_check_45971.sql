-- Check pg_net result for the latest Discord reaction upgrade request
SELECT
  id,
  status_code,
  created,
  (response_headers->>'content-type') AS content_type,
  left(content::text, 2000) AS body_preview,
  error_msg
FROM net._http_response
WHERE id = 45971
   OR id = 45964
ORDER BY id DESC;
