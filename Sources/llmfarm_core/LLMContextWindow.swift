//
//  LLMContextWindow.swift
//  llmfarm_core
//
//  Created by Marcus Hobbs on 12/9/24.
//  (see comments at EOF)

import Foundation

class LLMContextWindow {
  var maxTokens: Int = 2048  // TODO: make this configurable
  var maxResponseTokens: Int = 250  // TODO: make this configurable
  private let llama3CharactersPerToken: Double = 3.5
  private let llama3WordsPerToken: Double = 0.7
  private let finalAssistantMarker = "<|start_header_id|>assistant<|end_header_id|>\n"
  private let estimatedMinimumTurnSize = 250  // Adjust based on your needs
  private var roundTable: [Persona]
  private var roundTableIndex: Int = 0
  private var currentPersona: Persona
  private var conversation: [Turn] = []
  private var ragContent: String = ""  // TODO: Add RAG
  private var contextWindowDebug: [String] = []
  private enum ContextWindowError: Error {
    case exceededTokenBudget(section: String, available: Int, required: Int)
  }

  init() {
    // TODO: Generalize
    roundTable = [
      Personas.AncientTextWiseFriend,
      Personas.AncientTextCulturalBridge,
      Personas.AncientTextPracticalGuide,
    ]
    currentPersona = roundTable[roundTableIndex]
  }

  // just record the Turn created by the llm output, don't do anything else.
  // **** assumes that the currentPersona that prompted the model is the one responding.
  func llmResponded(with response: String) {
    let turn = Turn(content: response, persona: currentPersona, timestamp: Date())
    conversation.append(turn)
  }

  // just record the user's Turn, don't do anything else
  // i.e., don't change the currentPersona
  func userPrompted(with prompt: String) {
    let turn = Turn(content: prompt, persona: Personas.User, timestamp: Date())  // do not change currentPersona
    conversation.append(turn)
  }

  func createContextWindowForCurrentTurn() throws -> String {
    let contextWindowBudget = TokenBudget(
      remaining: maxTokens - maxResponseTokens - estimateTokens(for: finalAssistantMarker))
    var contextWindow = StringBuilder(
      budget: contextWindowBudget,
      createSectionFn: createSection,
      estimateTokensFn: estimateTokens
    )

    // 1. System Message
    let systemPrompt =
      currentPersona.systemPrompt
      + ". Limit your response to \(Int(llama3WordsPerToken * Double(maxResponseTokens))) words or less."

    try contextWindow.appendSection(
      "system",
      """
      [system]
      (<|begin_of_text|>
      \(systemPrompt)
      """
    )

    // 2. RAG Content
    if !ragContent.isEmpty {
      try contextWindow.appendRAGContent(ragContent)
    }

    // 3. Conversation History ---------------------
      let conversationBudget = TokenBudget(remaining: contextWindowBudget.remaining)
      var conversationSubwindow = StringBuilder(
        budget: conversationBudget,
        createSectionFn: createSection,
        estimateTokensFn: estimateTokens
      )
      
    // Most recent turn first
    if let lastTurn = conversation.last {
      try conversationSubwindow.appendSection("user", lastTurn.contentAsUserPersona())
    }

    // Prepend previous turns
    for turn in conversation.dropLast().reversed() {
        try conversationSubwindow.appendSection(turn.persona.identifier(), turn.contentAsPersona(), prepend: true)

      // Break if we can't fit more history
      if conversationBudget.remaining < estimatedMinimumTurnSize {
        break
      }
    }
      contextWindow.append(conversationSubwindow.toString())
      
      // 3. [end] Conversation History ---------------------

    // Final assistant marker
    contextWindow.append(finalAssistantMarker)

    return contextWindow.toString()
  }

  // Handle persona switching
  private func switchPersona(to newPersona: Persona) {
    currentPersona = newPersona
  }

  // Token estimation
  private func estimateTokens(for text: String) -> Int {
    // TODO: Implement efficient token counting, for now modified char count
    // NOTE: using the llama tokenizer is quite involved, and the one used for inference cannot be safely re-used simultaneously.
    // See LLama: LLMBase: llm_tokenize

    let tokenCount = Double(text.count) / llama3CharactersPerToken

    return Int(tokenCount)
  }

  private func enforceHeaderNewline(_ text: String) -> String {
    // Replace any existing multiple newlines after end_header_id with a single newline
    let multiNewlinePattern = "<\\|end_header_id\\|>\\s+"
    let intermediate = text.replacingOccurrences(
      of: multiNewlinePattern,
      with: "<|end_header_id|>\n",
      options: .regularExpression
    )

    // Ensure there is at least one newline after end_header_id
    let noNewlinePattern = "<\\|end_header_id\\|>(?![\\n])"
    return intermediate.replacingOccurrences(
      of: noNewlinePattern,
      with: "<|end_header_id|>\n",
      options: .regularExpression
    )
  }

  private func createSection(header: String, content: String, eot: Bool = true) -> String {
    """
    <|start_header_id|>\(header)<|end_header_id|>\n
    \(content)
    \(eot ? "<|eot_id|>\n" : "")
    """
  }

  // Private Helper types

  // MARK: Turn
  private struct Turn {
    let content: String
    let persona: Persona
    let timestamp: Date

    func contentAsPersona() -> String {
      return persona.name + ": " + content + "\n"
    }

    func contentAsUserPersona() -> String {
      return Personas.User.name + ": " + content + "\n"
    }
  }

  // MARK: StringBuilder
  private struct StringBuilder {
    private var content = ""
    private var budget: TokenBudget
    private let createSectionFn: (String, String, Bool) -> String
    private let estimateTokensFn: (String) -> Int

    init(
      budget: TokenBudget,
      createSectionFn: @escaping (String, String, Bool) -> String,
      estimateTokensFn: @escaping (String) -> Int
    ) {
      self.budget = budget
      self.createSectionFn = createSectionFn
      self.estimateTokensFn = estimateTokensFn
    }

    mutating func appendSection(_ header: String, _ content: String, prepend: Bool = false) throws {
      let section = createSectionFn(header, content, true)
      let tokens = estimateTokensFn(section)
      try budget.consume(tokens)
      if prepend {
        self.content = section + self.content
      } else {
        self.content += section
      }
    }

    mutating func appendRAGContent(_ content: String) throws {
      let section = createSectionFn("user", content, true)
      let tokens = estimateTokensFn(section)
      try budget.consume(tokens)
      self.content += section
    }

    // this is dangerous because it doesn't check for token budget
    mutating func append(_ content: String) {
      self.content += content
    }

    func toString() -> String {
      return content
    }
  }

  // MARK: TokenBudget
  private struct TokenBudget {
    var remaining: Int

    mutating func consume(_ tokens: Int) throws {
      guard tokens <= remaining else {
        throw ContextWindowError.exceededTokenBudget(
          section: "section",
          available: remaining,
          required: tokens
        )
      }
      remaining -= tokens
    }
  }
}

// Context window management, created every turn (not every token).
// We're creating the context window as a String, and it still needs to be tokenized.

// Fundamental idea: the most recent Turn IS THE PROMPT for the next Turn.

// i.e., if you are the User and you prompt--that's added as a User persona Turn.
//       if you are a member of the roundtable, your response is the "user" prompt

/*
   "prompt_format" : "[system](<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are an AI<|eot_id|>)\n\n\n<|start_header_id|>user<|end_header_id|>\n\n\n{prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>"
   */

/* from Claude:
   <|begin_of_text|><|start_header_id|>system<|end_header_id|>

   [Your base system prompt defining the roundtable rules and persona behaviors]<|eot_id|>

   <|start_header_id|>user<|end_header_id|>

   [RAG content or context injection]<|eot_id|>

   <|start_header_id|>persona_alice<|end_header_id|>

   [Alice's contribution]<|eot_id|>

   <|start_header_id|>persona_bob<|end_header_id|>

   [Bob's response]<|eot_id|>

   <|start_header_id|>user<|end_header_id|>

   [Current user/persona input]<|eot_id|>

   <|start_header_id|>assistant<|end_header_id|>
   */
