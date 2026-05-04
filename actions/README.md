# Actions after LLM olly

You may want to do some actions after the LLM olly finishes its job. For example, you may want to save the agent session, or you may want to disable some tools when they are not needed. The bottom line is that you should decide what you want to do after the LLM olly, not let the LLM CLI providers decide for you.

Goals:
1. Get more control over the agent session
1. Save tokens by using less tokens in the prompt.
1. Make the agent session more efficient by only enabling tools when needed, instead of having all tools enabled by default.

Note:
1. CLIs is under rapid development, so the interface may change in the future. Please refer to the code for the latest usage.
