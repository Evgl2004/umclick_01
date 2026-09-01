from rest_framework import serializers

from apps.quiz.models import Choice, Question, Quiz
from django.core.exceptions import ValidationError
from django.db import transaction
from apps.quiz.validation import quiz_data, validate_quiz_data


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
        self._merged(attrs, self.instance)
        return attrs

    def _merged(self, attrs, instance):
        previous = quiz_data(instance) if instance else {}
        data = {**previous, **attrs}
        old_questions = {q['id']: q for q in previous.get('questions', [])}
        questions, seen_questions = [], set()
        for i, source in enumerate(data.get('questions', [])):
            qid = source.get('id')
            if qid is not None and (qid not in old_questions or qid in seen_questions):
                raise serializers.ValidationError({f'questions.{i}.id': 'Вопрос не принадлежит викторине или повторяется.'})
            seen_questions.add(qid)
            question = {**old_questions.get(qid, {}), **source, 'order': i + 1}
            old_choices = {c['id']: c for c in old_questions.get(qid, {}).get('choices', [])}
            choices, seen_choices = [], set()
            for j, item in enumerate(question.get('choices', [])):
                cid = item.get('id')
                if cid is not None and (cid not in old_choices or cid in seen_choices):
                    raise serializers.ValidationError({f'questions.{i}.choices.{j}.id': 'Вариант не принадлежит вопросу или повторяется.'})
                seen_choices.add(cid)
                choices.append({**old_choices.get(cid, {}), **item, 'order': j + 1})
            question['choices'] = choices
            questions.append(question)
        data['questions'] = questions
        try:
            validate_quiz_data(data)
        except ValidationError as exc:
            raise serializers.ValidationError(exc.message_dict) from exc
        return data

    @transaction.atomic
    def create(self, validated_data):
        data = self._merged(validated_data, None)
        questions = data.pop('questions')
        quiz = Quiz.objects.create(**data)
        self._save_questions(quiz, questions)
        return quiz

    @transaction.atomic
    def update(self, instance, validated_data):
        instance = Quiz.objects.select_for_update().get(pk=instance.pk)
        data = self._merged(validated_data, instance)
        questions = data.pop('questions')
        for field, value in data.items():
            setattr(instance, field, value)
        instance.save()
        if 'questions' in validated_data:
            self._save_questions(instance, questions)
        return instance

    def _save_questions(self, quiz, questions):
        retained = []
        for source in questions:
            data = dict(source)
            choices = data.pop('choices')
            qid = data.pop('id', None)
            question = quiz.questions.get(pk=qid) if qid else Question(quiz=quiz)
            for field, value in data.items():
                setattr(question, field, value)
            question.save()
            retained.append(question.pk)
            choice_ids = []
            for source_choice in choices:
                choice_data = dict(source_choice)
                cid = choice_data.pop('id', None)
                choice = question.choices.get(pk=cid) if cid else Choice(question=question)
                for field, value in choice_data.items():
                    setattr(choice, field, value)
                choice.save()
                choice_ids.append(choice.pk)
            question.choices.exclude(pk__in=choice_ids).delete()
        quiz.questions.exclude(pk__in=retained).delete()
