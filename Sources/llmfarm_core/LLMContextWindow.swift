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

  // Estimate tokens for Llama3 models
  let llama3CharactersPerToken: Double = 3.5
  let llama3WordsPerToken: Double = 0.7

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

  func createContextWindowForCurrentTurn() -> String {
    let assistantResponseWordBudget = Int(llama3WordsPerToken * Double(maxResponseTokens))
    let finalAssistantMarker: String = "<|start_header_id|>assistant<|end_header_id|>\n"
    let finalAssistantMarkerTokens = estimateTokens(for: finalAssistantMarker)
    let contextWindowTokenBudget = maxTokens - maxResponseTokens - finalAssistantMarkerTokens
    var finalNumTokens: Int = 0
    var finalContextWindow: String = ""

    // 1. System Message
    // system prompt is a combination of the current persona, and additional instructions to facilitate conversations and manage context.
    let personaPrompt = currentPersona.systemPrompt

    let additionalInstructions = ". Limit your response to \(assistantResponseWordBudget) or less."

    let finalSystemPrompt = personaPrompt + additionalInstructions
    let systemSection = """
      [system]
      (<|begin_of_text|><|start_header_id|>system<|end_header_id|>
      \n\n\(finalSystemPrompt)<|eot_id|>\n\n\n
      """
    let estimatedSystemSectionTokens = estimateTokens(for: systemSection)
    if estimatedSystemSectionTokens + finalNumTokens >= contextWindowTokenBudget {
      fatalError("Context window exceeds token budget at system prompt")
    } else {
      finalNumTokens += estimatedSystemSectionTokens
      finalContextWindow += systemSection
    }

    // 2. RAG Content (if any) - Insert as a system message
    var ragSection: String = ""
    if !ragContent.isEmpty {
      for chunk in ragContent {
        let chunkEntry = """
          <|start_header_id|>user<|end_header_id|>\n\n\(chunk)<|eot_id|>\n\n
          """
        let chunkTokens = estimateTokens(for: chunkEntry)
        if finalNumTokens + chunkTokens > contextWindowTokenBudget {
          fatalError("Context window exceeds token budget RAG")
        } else {
          finalNumTokens += chunkTokens
          ragSection.append(chunkEntry)
        }
      }
      let estimatedRagSectionTokens = estimateTokens(for: ragSection)
      if estimatedRagSectionTokens + finalNumTokens >= contextWindowTokenBudget {
        fatalError("Context window exceeds token budget RAG")
      } else {
        finalNumTokens += estimatedRagSectionTokens
        finalContextWindow += ragSection
      }
    }

    // 3. Conversation History
    // Walk backwards through conversation, starting with current user message

    // Add most recent turn as current ***user*** message using contentAsUserPersona
    if let (_, lastTurn) = conversation.enumerated().reversed().first {
      let currentUserMessage =
        """
        <|start_header_id|>user<|end_header_id|>\n
        \(lastTurn.contentAsUserPersona())
        <|eot_id|>
        """
      let currentUserMessageTokens = estimateTokens(for: currentUserMessage)
      if currentUserMessageTokens + finalNumTokens >= contextWindowTokenBudget {
        fatalError("Context window exceeds token budget for most recent turn")
      } else {
        finalNumTokens += currentUserMessageTokens
        finalContextWindow += currentUserMessage
      }
    }

    // add the turns within budget
    for (_, turn) in conversation.dropLast().enumerated().reversed() {
      let turnMessage = """
        <|start_header_id|>\(turn.persona.identifier())<|end_header_id|>\n
        \(turn.contentAsPersona())
        <|eot_id|>
        """
      let turnTokens = estimateTokens(for: turnMessage)
      if turnTokens + finalNumTokens >= contextWindowTokenBudget {
        fatalError("Context window exceeds token budget for turn \(turn.persona.identifier())")
      } else {
        finalNumTokens += turnTokens
        finalContextWindow += turnMessage
      }
    }

    // add the final system turn for inference, already accounted for
    finalContextWindow += finalAssistantMarker

    // we're done!
    return finalContextWindow
  }

  // Handle persona switching
  private func switchPersona(to newPersona: Persona) {
    // Preserve conversation and RAG content
    currentPersona = newPersona
    // Recalculate token budget
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
}
