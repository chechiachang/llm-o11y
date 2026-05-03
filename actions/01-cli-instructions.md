# CLI Default Instructions

There are some default instructions from CLI, which are not necessary for every agent session, and they take up a lot of tokens in the prompt.

1. Override the default cli prompt to a minimal one
2. Disable enabled tools by default, and only enable tools when needed.
  1. codex-cli has 17 default tools enabled, which takes up a lot of tokens in the prompt.
     There is no way to disable them by default
  2. opencoder-cli has 10 default tools enabled, which also takes up a lot of tokens in the prompt. There is no way to disable them by default

### Tools

```
# opencode 1.14.28
Tools: bash, read, glob, grep, task, webfetch, todowrite, apply_patch, multi_tool_use

# codex cli v0.125.0
  - web.run → web search/open/find/news/finance/weather/sports/time/calc/image search
  - image_gen.imagegen → generate/edit images
  - functions.exec_command → run shell command
  - functions.write_stdin → send input to running shell session
  - functions.list_mcp_resources
  - functions.list_mcp_resource_templates
  - functions.read_mcp_resource
  - functions.update_plan
  - functions.request_user_input (Plan mode only; now unavailable)
  - functions.view_image
  - functions.spawn_agent
  - functions.send_input
  - functions.resume_agent
  - functions.wait_agent
  - functions.close_agent
  - functions.apply_patch → edit files by patch
  - multi_tool_use.parallel → run multiple developer tools in parallel
```

