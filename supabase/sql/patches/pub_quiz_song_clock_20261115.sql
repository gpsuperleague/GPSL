-- Music questions get 18 seconds. Text stays 10–14. Pictures stay up to 14.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_answer_seconds(
  p_prompt text,
  p_a text,
  p_b text,
  p_c text,
  p_kind text
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(coalesce(p_kind, '')) = 'song' THEN 18
    ELSE least(
      14,
      greatest(
        10,
        10
        + CASE
            WHEN length(btrim(coalesce(p_prompt, '')))
               + length(btrim(coalesce(p_a, '')))
               + length(btrim(coalesce(p_b, '')))
               + length(btrim(coalesce(p_c, ''))) <= 80 THEN 0
            WHEN length(btrim(coalesce(p_prompt, '')))
               + length(btrim(coalesce(p_a, '')))
               + length(btrim(coalesce(p_b, '')))
               + length(btrim(coalesce(p_c, ''))) <= 130 THEN 1
            WHEN length(btrim(coalesce(p_prompt, '')))
               + length(btrim(coalesce(p_a, '')))
               + length(btrim(coalesce(p_b, '')))
               + length(btrim(coalesce(p_c, ''))) <= 190 THEN 2
            WHEN length(btrim(coalesce(p_prompt, '')))
               + length(btrim(coalesce(p_a, '')))
               + length(btrim(coalesce(p_b, '')))
               + length(btrim(coalesce(p_c, ''))) <= 250 THEN 3
            ELSE 4
          END
        + CASE WHEN lower(coalesce(p_kind, '')) = 'picture' THEN 2 ELSE 0 END
      )
    )
  END;
$$;

SELECT
  public.gpsl_pub_quiz_answer_seconds('Name this song.', 'A', 'B', 'C', 'song') AS song,
  public.gpsl_pub_quiz_answer_seconds('Short one?', 'Yes', 'No', 'Maybe', 'text') AS text,
  public.gpsl_pub_quiz_answer_seconds('Who is this?', 'A', 'B', 'C', 'picture') AS picture;
