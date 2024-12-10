//
//  LLMContextWindow.swift
//  llmfarm_core
//
//  Created by Marcus Hobbs on 12/9/24.
//

import Foundation

class LLMContextWindow {

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

  var maxTokens: Int = 2048  // TODO: make this configurable
  // TODO: Need a max prompt tokens argh
  var maxResponseTokens: Int = 250  // TODO: make this configurable
  var promptTemplate: String = ""
  /*
    "prompt_format" : "[system](<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are an AI<|eot_id|>)\n\n\n<|start_header_id|>user<|end_header_id|>\n\n\n{prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>"
  */

  private var roundTable: [Persona]
  private var roundTableIndex: Int = 0
  private var currentPersona: Persona
  private var conversation: [Turn] = []
  private var ragContent: String = ""  // TODO: Add RAG
  private var contextWindowDebug: [String] = []

  init() {
    // TODO: Generalize
    roundTable = [
      Personas.AncientTextWiseFriend, Personas.AncientTextCulturalBridge,
      Personas.AncientTextPracticalGuide,
    ]
    currentPersona = roundTable[roundTableIndex]
  }

  // just record the Turn created by the llm output, don't do anything else
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

  // Context window management, created every turn (not every token).
  // We're creating the context window as a String, and it still needs to be tokenized.

  // Fundamental idea: the most recent Turn IS THE PROMPT for the next Turn.

  // i.e., if you are the User and you prompt--that's added as a User persona Turn.
  //       if you are a member of the roundtable, your response is the "user" prompt

  /*
    "prompt_format" : "[system](<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are an AI<|eot_id|>)\n\n\n<|start_header_id|>user<|end_header_id|>\n\n\n{prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>"
  */

  private func createContextWindow() -> String {
    let tokenBudget = maxTokens - maxResponseTokens
    var numTokens: Int = 0

    // 1. System Message
    let systemSection = """
      [system]
      (<|begin_of_text|><|start_header_id|>system<|end_header_id|>
      \n\n\(currentPersona.systemPrompt)<|eot_id|>\n\n\n
      """
    numTokens += estimateTokens(for: systemSection)

    // 2. RAG Content (if any) - Insert as a system message
    var ragSection: String = ""
    if !ragContent.isEmpty {
      for chunk in ragContent {
        let chunkEntry = """
          <|start_header_id|>retrieved<|end_header_id|>\n\n\(chunk)<|eot_id|>\n\n
          """
        let chunkTokens = estimateTokens(for: chunkEntry)
        if numTokens + chunkTokens > tokenBudget {
          fatalError("Context window exceeds token budget RAG")
        } else {
          ragSection.append(chunkEntry)
        }
      }
    }

    // 5. Add Assistant marker for the response
    let assistantMarker = "<|start_header_id|>assistant<|end_header_id|>"
    let assistantMarkerTokens = estimateTokens(for: assistantMarker)
    if numTokens + assistantMarkerTokens > tokenBudget {
      fatalError("Context window exceeds token budget")
    }

    // 3. Conversation History
    // Walk backwards through conversation, starting with current user message
    var conversationHistory = ""
    if let (_, lastTurn) = conversation.enumerated().reversed().first {
      // Add most recent turn as current user message using contentAsUserPersona
      let currentUserMessage = """
        <|start_header_id|>user<|end_header_id|>
        \(lastTurn.contentAsUserPersona())
        <|eot_id|>
        """
      context += currentUserMessage
      numTokens += estimateTokens(for: currentUserMessage)

      // Add previous turns using contentAsPersona
      for (_, turn) in conversation.dropLast().enumerated().reversed() {
        let turnMessage = """
          <|start_header_id|>user<|end_header_id|>
          \(turn.contentAsPersona())
          <|eot_id|>
          """

        let assistantMessage = """
          <|start_header_id|>assistant<|end_header_id|>
          <|eot_id|>
          """

        let turnTokens = estimateTokens(for: turnMessage) + estimateTokens(for: assistantMessage)
        if (numTokens + turnTokens) > tokenBudget {
          break
        }

        context = turnMessage + assistantMessage + context
        numTokens += turnTokens
      }
    }

    return context
  }

  func createContextWindow(
    systemPrompt: String,
    ragChunks: [String],
    history: [(speaker: String, content: String)],
    userPrompt: String,
    maxTokens: Int,
    leaveForAssistant: Int
  ) -> String {
    let tokenBudget = maxTokens - maxResponseTokens
    var numTokens: Int = 0
    var context: String = ""

    // Step 1: Start with the system prompt
    let systemSection = """
      [system]
      (<|begin_of_text|><|start_header_id|>system<|end_header_id|>
      \n\n\(systemPrompt)<|eot_id|>)\n\n\n
      """
    context += systemSection
    numTokens += estimateTokens(for: systemSection)

    // Step 2: Add RAG chunks
    for chunk in ragChunks {
      let chunkEntry = """
        <|start_header_id|>retrieved<|end_header_id|>\n\n\(chunk)<|eot_id|>\n\n
        """
      context.append(chunkEntry)
    }

    // Step 3: Add conversation history
    var tokenCount = estimateTokens(for: context)  // Helper to count tokens
    for (speaker, content) in history.reversed() {  // Add from latest to oldest
      let turn = """
        <|start_header_id|>\(speaker)<|end_header_id|>\n\n\(content)<|eot_id|>\n\n
        """
      let turnTokens = estimateTokens(for: turn)
      if tokenCount + turnTokens + leaveForAssistant <= maxTokens {
        context.append(turn)
        tokenCount += turnTokens
      } else {
        break  // Stop adding history if we exceed the token limit
      }
    }

    // Step 4: Add the user prompt
    let userTurn = """
      <|start_header_id|>user<|end_header_id|>\n\n\(userPrompt)<|eot_id|>\n\n
      """
    context.append(userTurn)

    // Step 5: Add placeholder for assistant
    let assistantTurn = """
      <|start_header_id|>assistant<|end_header_id|>\n\n
      """
    context.append(assistantTurn)

    return context
  }

  // Handle persona switching
  private func switchPersona(to newPersona: Persona) {
    // Preserve conversation and RAG content
    currentPersona = newPersona
    // Recalculate token budget
  }

  // Token estimation
  private func estimateTokens(for text: String) -> Int {
    // TODO: Implement efficient token counting, for now char count
    let tokenCount = text.count

    return tokenCount
  }
}
