You are ONE iteration of an autonomous build loop. Work ONLY inside the current directory. Be fast and minimal.

GOAL: the directory ./out/ should eventually contain out/1.txt, out/2.txt, out/3.txt — each file containing only its number (out/2.txt contains the single character 2).

YOUR JOB THIS ITERATION:

1. List ./out/ to see which of out/1.txt, out/2.txt, out/3.txt already exist.
2. If all three already exist: create/modify/delete NOTHING and print exactly this token: <promise>NO_MORE_TASKS</promise>
3. Otherwise: create EXACTLY ONE file — the lowest-numbered one that does not yet exist — containing only its number, then print exactly this token: <promise>CONTINUE</promise>

Do not create, modify, or delete any other file. Print the promise token as the final line of your response.
