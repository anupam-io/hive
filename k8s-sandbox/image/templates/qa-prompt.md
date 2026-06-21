Follow the `hive-qa` skill — it defines the QA method and the report format.

Target app: ${WEB_URL}
${QA_TARGET_LINE}
Baseline capture from a prior Playwright run — read with the Read tool (Read
supports PNG images):

${SHOT_LIST}- ${PAGE_TXT} — rendered document.body.innerText
- ${CONSOLE_LOG} — every browser console event during load
- ${NETWORK_LOG} — every failed request / non-2xx response during load
- ${META_JSON} — capture metadata + any baseline errors

You also have a LIVE Playwright browser via the playwright MCP — drive it
yourself to do everything the baseline can't show you (navigate to ${WEB_URL},
scroll below the fold, hover/click interactive elements, resize to a mobile
viewport, visit every route, screenshot whenever it sharpens a claim). Live
interaction is the heart of the job; the baseline only exists for
console/network grounding.

Do NOT run git or gh — the harness publishes your report as the feedback issue.
End your reply with exactly one line:
RESULT: REPORTED
