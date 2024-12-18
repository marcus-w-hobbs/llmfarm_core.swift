//
//  ArrayExt.swift
//  Created by Guinmoon.

import Accelerate

extension Array {

  // Convenience unsafe mutable pointer - Apple's method is annoying
  public var mutPtr: UnsafeMutablePointer<Element> {
    mutating get {
      self.withUnsafeMutableBufferPointer({ $0 }).baseAddress!
    }
  }

  // Split the array evenly into an array of arrays
  public func split(_ count: Int) -> [[Element]] {
    var split: [[Element]] = []
    let splitCount = self.count / count
    for i in 0..<count {
      let start = i * splitCount
      let end = start + splitCount
      split.append([Element](self[start..<end]))
    }
    return split
  }

}
