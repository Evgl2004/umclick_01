from rest_framework import serializers

from apps.quiz.models import Choice, Question, Quiz


class ChoiceSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(required=False)

    class Meta:
        model = Choice
        fields = ["id", "text", "is_correct", "order"]


class QuestionSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(required=False)
    choices = ChoiceSerializer(many=True)

    class Meta:
        model = Question
        fields = ["id", "text", "order", "time_limit_sec", "choices"]


class QuizSerializer(serializers.ModelSerializer):
    questions = QuestionSerializer(many=True)

    class Meta:
        model = Quiz
        fields = [
            "id",
            "title",
            "description",
            "question_only_on_display",
            "show_choices_on_participant",
            "reading_time_sec",
            "results_time_sec",
            "questions",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ["created_at", "updated_at"]

    def validate(self, attrs):
        reading_time = attrs.get("reading_time_sec", 15)
        results_time = attrs.get("results_time_sec", 10)
        if reading_time < 3 or reading_time > 120:
            raise serializers.ValidationError(
                {"reading_time_sec": "Reading time must be between 3 and 120 seconds."}
            )
        if results_time < 3 or results_time > 60:
            raise serializers.ValidationError(
                {"results_time_sec": "Results time must be between 3 and 60 seconds."}
            )
        return attrs

    def create(self, validated_data):
        questions_data = validated_data.pop("questions", [])
        quiz = Quiz.objects.create(**validated_data)
        self._create_questions(quiz, questions_data)
        return quiz

    def update(self, instance, validated_data):
        questions_data = validated_data.pop("questions", None)
        instance.title = validated_data.get("title", instance.title)
        instance.description = validated_data.get("description", instance.description)
        instance.question_only_on_display = validated_data.get(
            "question_only_on_display",
            instance.question_only_on_display,
        )
        instance.show_choices_on_participant = validated_data.get(
            "show_choices_on_participant",
            instance.show_choices_on_participant,
        )
        instance.reading_time_sec = validated_data.get("reading_time_sec", instance.reading_time_sec)
        instance.results_time_sec = validated_data.get("results_time_sec", instance.results_time_sec)
        instance.save()

        if questions_data is not None:
            instance.questions.all().delete()
            self._create_questions(instance, questions_data)

        return instance

    def _create_questions(self, quiz, questions_data):
        for question_data in questions_data:
            choices_data = question_data.pop("choices", [])
            question = Question.objects.create(quiz=quiz, **question_data)
            for choice_data in choices_data:
                Choice.objects.create(question=question, **choice_data)
