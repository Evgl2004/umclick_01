from rest_framework import serializers

from apps.quiz.services import (
    create_quiz_with_draft,
    get_effective_version,
    save_quiz_content,
    version_data,
)


class ChoiceSerializer(serializers.Serializer):
    id = serializers.IntegerField(required=False)
    text = serializers.CharField(max_length=255)
    is_correct = serializers.BooleanField(required=False, default=False)
    order = serializers.IntegerField(min_value=1, required=False)


class QuestionSerializer(serializers.Serializer):
    id = serializers.IntegerField(required=False)
    text = serializers.CharField()
    order = serializers.IntegerField(min_value=1, required=False)
    time_limit_sec = serializers.IntegerField(required=False, default=20)
    choices = ChoiceSerializer(many=True, required=False)


class QuizSerializer(serializers.Serializer):
    id = serializers.IntegerField(read_only=True)
    title = serializers.CharField(max_length=255, required=False)
    description = serializers.CharField(required=False, allow_blank=True)
    question_only_on_display = serializers.BooleanField(required=False)
    show_choices_on_participant = serializers.BooleanField(required=False)
    reading_time_sec = serializers.IntegerField(required=False)
    results_time_sec = serializers.IntegerField(required=False)
    questions = QuestionSerializer(many=True, required=False)
    content_revision = serializers.IntegerField(min_value=1, required=False)
    archived_at = serializers.DateTimeField(read_only=True, allow_null=True)
    can_delete = serializers.BooleanField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)
    updated_at = serializers.DateTimeField(read_only=True)

    def validate(self, attrs):
        if self.instance is None:
            if 'content_revision' in attrs:
                raise serializers.ValidationError({
                    'content_revision': 'Редакция назначается сервером.'
                })
        elif 'content_revision' not in attrs:
            raise serializers.ValidationError({
                'content_revision': 'Укажите редакцию загруженного содержимого.'
            })
        return attrs

    def create(self, validated_data):
        return create_quiz_with_draft(
            actor=self.context['request'].user,
            data=validated_data,
        )

    def update(self, instance, validated_data):
        expected_revision = validated_data.pop('content_revision')
        return save_quiz_content(
            quiz_id=instance.pk,
            actor=self.context['request'].user,
            expected_revision=expected_revision,
            data=validated_data,
        )

    def to_representation(self, instance):
        version = get_effective_version(instance)
        content = version_data(version) if version is not None else {
            'title': '',
            'description': '',
            'question_only_on_display': False,
            'show_choices_on_participant': True,
            'reading_time_sec': 15,
            'results_time_sec': 10,
            'questions': [],
        }
        can_delete = getattr(instance, 'can_delete', None)
        if can_delete is None:
            from apps.session.models import LiveSession

            can_delete = not LiveSession.objects.filter(
                quiz_version__quiz=instance,
            ).exists()
        return {
            'id': instance.pk,
            **content,
            'content_revision': instance.content_revision,
            'archived_at': (
                self.fields['archived_at'].to_representation(instance.archived_at)
                if instance.archived_at is not None
                else None
            ),
            'can_delete': can_delete,
            'created_at': self.fields['created_at'].to_representation(instance.created_at),
            'updated_at': self.fields['updated_at'].to_representation(instance.updated_at),
        }
