import 'package:flutter/material.dart';

class QuizDraftChoice {
  QuizDraftChoice({String text = '', this.isCorrect = false})
      : textController = TextEditingController(text: text);

  final TextEditingController textController;
  bool isCorrect;

  void dispose() {
    textController.dispose();
  }
}

class QuizDraftQuestion {
  QuizDraftQuestion({
    String text = '',
    int timeLimitSec = 20,
    List<QuizDraftChoice>? choices,
  })  : textController = TextEditingController(text: text),
        timeLimitController = TextEditingController(text: '$timeLimitSec'),
        choices = choices ?? [QuizDraftChoice(), QuizDraftChoice()];

  final TextEditingController textController;
  final TextEditingController timeLimitController;
  final List<QuizDraftChoice> choices;

  void dispose() {
    textController.dispose();
    timeLimitController.dispose();
    for (final choice in choices) {
      choice.dispose();
    }
  }
}

class QuizDisplaySettings {
  const QuizDisplaySettings({
    this.questionOnlyOnDisplay = false,
    this.showChoicesOnParticipant = true,
    this.readingTimeSec = 15,
    this.resultsTimeSec = 10,
  });

  final bool questionOnlyOnDisplay;
  final bool showChoicesOnParticipant;
  final int readingTimeSec;
  final int resultsTimeSec;
}
