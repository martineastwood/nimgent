---
title: nimgent
description: A native Nim library for LLM apps and agents. Streaming, typed tools, structured output, and one API across providers.
template: splash
hero:
  title: The typed AI library for Nim
  tagline: Stream, call tools, and decode results through one API across providers.
  actions:
    - text: Get started
      link: /introduction/
      variant: primary
      icon: right-arrow
    - text: View on GitHub
      link: https://github.com/martineastwood/nimgent
      variant: secondary
      icon: external
---

<div class="landing-shell not-content">
  <p class="landing-lede">Install nimgent, pick a provider, and call a model from  Nim. Stream tokens, run typed tools, decode structured output into Nim types, chat with documents, and ground answers with RAG.</p>

  <section class="landing-terminal" aria-labelledby="landing-terminal-title">
    <div class="landing-terminal-bar">
      <div class="landing-terminal-dots" aria-hidden="true"><span></span><span></span><span></span></div>
      <span id="landing-terminal-title">agent.nim</span>
      <span class="landing-terminal-mode">openai</span>
    </div>
    <pre class="not-content"><code><span class="kw">import</span> std/os
<span class="kw">import</span> nimgent
<span class="kw">import</span> nimgent/agent
<span class="kw">import</span> nimgent/providers/openai&#10;&#10;<span class="kw">let</span> model = openAI(getEnv(<span class="str">&quot;OPENAI_API_KEY&quot;</span>)).model(<span class="str">&quot;gpt-4o-mini&quot;</span>)
<span class="kw">let</span> assistant = newAgent(
  model,
  instructions = <span class="str">&quot;You are a helpful assistant.&quot;</span>)&#10;
<span class="kw">echo</span> assistant.run(<span class="str">&quot;What is the Nim programming language?&quot;</span>).text</code></pre>
  </section>

  <section class="landing-section" aria-labelledby="landing-runtime-title">
    <p class="landing-kicker">Native Nim</p>
    <h2 id="landing-runtime-title">A library you can keep in the binary</h2>
    <p class="landing-section-intro">Nimgent is ordinary Nim. It compiles into your program, talks to providers over HTTP, and does not require a hosted service or a language runtime beside the binary you already ship.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>One API, many providers</h3>
        <p>OpenAI, Anthropic, Google Gemini, Mistral, OpenRouter, Hyper, and OpenCode share the same request model. Switch the constructor, keep the rest of the call.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Blocking or async</h3>
        <p>Use the blocking helpers in a script. Use the async APIs when your application already runs Nim's event loop.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Your provider, your keys</h3>
        <p>Requests go straight to the API you pick. Credentials stay in the environment you already use to run the program.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>No framework required</h3>
        <p>Start with <code>generateText</code>. Add an agent, a conversation, or middleware when the application needs them.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-work-title">
    <p class="landing-kicker">In your program</p>
    <h2 id="landing-work-title">From a prompt to a typed result</h2>
    <p class="landing-section-intro">Ask for the outcome you want. Nimgent sends the request, runs the tools you registered, and gives you text, events, or a validated Nim value.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>Generate text</h3>
        <p>Send a prompt, optional system instruction, and read <code>response.text</code> when the turn finishes.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Stream as it arrives</h3>
        <p>Render text, thinking, tool calls, and agent events through a callback. Return false when you need to cancel.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Call typed tools</h3>
        <p>Declare a Nim input type. The model sees the schema, and your handler receives a decoded value instead of raw JSON.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Decode structured output</h3>
        <p>Use <code>generateObject[T]</code> when the answer should be a Nim value. The response is validated before you see it.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-customize-title">
    <p class="landing-kicker">Typed at the boundary</p>
    <h2 id="landing-customize-title">Nim types in, Nim types out</h2>
    <p class="landing-section-intro">A tool is a name, a description, and a callback over a Nim object. Nimgent derives the JSON Schema the model sees and decodes arguments before your code runs.</p>
    <div class="landing-extend">
      <div class="landing-code">
        <div class="landing-code-bar"><span>weather.nim</span></div>
        <pre class="not-content"><code><span class="kw">type</span> WeatherInput = <span class="kw">object</span>
  city: string&#10;
<span class="kw">let</span> weather = tool(<span class="str">&quot;get_weather&quot;</span>, <span class="str">&quot;Get the weather for a city&quot;</span>,
  <span class="kw">proc</span> (_: ToolContext, input: WeatherInput): string =
    input.city &amp; <span class="str">&quot;: 16C and cloudy&quot;</span>)&#10;
<span class="kw">let</span> response = generateText(
  model,
  prompt = <span class="str">&quot;What is the weather like in Paris?&quot;</span>,
  tools = @[weather],
  maxSteps = 5)</code></pre>
      </div>
      <div class="landing-grid">
        <article class="landing-card">
          <span class="landing-card-index">01</span>
          <h3>Reuse an agent</h3>
          <p>Put the model, instructions, tools, and step limit in <code>newAgent</code>, then call <code>run</code> for each new task.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">02</span>
          <h3>Keep a conversation</h3>
          <p>Wrap the agent in a <code>Conversation</code> when follow-ups should include earlier messages and tool results.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">03</span>
          <h3>Connect MCP tools</h3>
          <p>Connect to an MCP server over stdio or HTTP, then call discovered tools directly or pass them to an agent.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">04</span>
          <h3>Ground answers locally</h3>
          <p>Embed documents, search an in-memory vector store, and put the matching passages in the prompt.</p>
        </article>
      </div>
    </div>
    <div class="landing-links">
      <a href="/guides/tools-and-agents/" class="landing-link"><span>Tools and agents</span><small>Typed local functions, bounded loops, and reusable agents.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/structured-output/" class="landing-link"><span>Structured output</span><small>Turn a model response into a validated Nim value.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/mcp/" class="landing-link"><span>MCP tools</span><small>Discover and call tools from an MCP server at runtime.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/embeddings-rag/" class="landing-link"><span>Embeddings and RAG</span><small>Index a corpus, search it, and ground the next prompt.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/conversations/" class="landing-link"><span>Conversations</span><small>Keep history across runs, then save and restore it.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-section landing-split" aria-labelledby="landing-interfaces-title">
    <div>
      <p class="landing-kicker">One library, several entry points</p>
      <h2 id="landing-interfaces-title">Use the call that fits the job</h2>
      <p class="landing-section-intro">The same model object can return a complete answer, a stream of events, a typed object, or a multi-step agent run.</p>
    </div>
    <div class="landing-links">
      <a href="/examples/generate-text/" class="landing-link"><span>generateText</span><small>Send a prompt and wait for the finished reply.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/streaming/" class="landing-link"><span>streamText</span><small>Render tokens and events as they arrive.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/structured-output/" class="landing-link"><span>generateObject</span><small>Decode the response into a Nim type.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/tools-and-agents/" class="landing-link"><span>newAgent</span><small>Reuse model, tools, and limits across many runs.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-start" aria-labelledby="landing-start-title">
    <div>
      <p class="landing-kicker">Start in a few lines</p>
      <h2 id="landing-start-title">Bring your provider. Keep your types.</h2>
      <p>Install nimgent with Nimble, set a provider key, and compile a small program with -d:ssl in the project you want to call from.</p>
    </div>
    <pre><code><span class="landing-prompt">$</span> nimble install nimgent
<span class="landing-prompt">$</span> export OPENAI_API_KEY=your-key
<span class="landing-prompt">$</span> nim c -r -d:ssl agent.nim</code></pre>
  </section>

  <p class="landing-footer-link"><a href="/introduction/">Get Started</a> or <a href="https://github.com/martineastwood/nimgent">view nimgent on GitHub</a>.</p>
</div>
