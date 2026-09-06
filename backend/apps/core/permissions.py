from rest_framework.permissions import BasePermission


def is_admin(user):
    return bool(user and user.is_authenticated and user.is_active and user.is_staff)


def is_teacher(user):
    return bool(user and user.is_authenticated and user.is_active and user.groups.filter(name='teacher').exists())


def can_manage_quiz(user, quiz):
    return is_admin(user) or (
        is_teacher(user) and quiz.owner_id == user.pk
    )


def can_manage_session(user, session):
    return can_manage_quiz(user, session.quiz_version.quiz)


class IsTeacher(BasePermission):
    message = 'Требуются права преподавателя или администратора.'

    def has_permission(self, request, view):
        user = request.user
        return is_admin(user) or is_teacher(user)
