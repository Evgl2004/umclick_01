import inspect

from django.test import SimpleTestCase

from apps.session import gameplay


class StageBStaticConcurrencyTests(SimpleTestCase):
    def test_answer_sql_is_parameterized_and_locks_only_run(self):
        source = inspect.getsource(gameplay._lock_trusted_current_run_for_answer)
        self.assertIn('FOR SHARE OF run', source)
        self.assertGreaterEqual(source.count('%s'), 8)
        self.assertIn('session_id,', source)
        self.assertNotIn("f'''", source)
        self.assertNotIn('FOR SHARE OF live', source)

    def test_answer_transaction_uses_the_agreed_lock_and_time_order(self):
        source = inspect.getsource(gameplay.record_answer_attempt)
        run_lock = source.index('_lock_trusted_current_run_for_answer')
        admitted_at = source.index('admitted_at = database_now()')
        participant_lock = source.index('SessionParticipant.objects.select_for_update()')
        self.assertLess(run_lock, admitted_at)
        self.assertLess(admitted_at, participant_lock)
        self.assertIsNotNone(getattr(gameplay.record_answer_attempt, '__wrapped__', None))

    def test_finalizer_uses_explicit_exclusive_run_lock_inside_atomic_transition(self):
        lock_source = inspect.getsource(gameplay._lock_current_run)
        transition_source = inspect.getsource(gameplay.advance_one_transition)
        self.assertIn('SessionQuestionRun.objects.select_for_update()', lock_source)
        self.assertIn('_lock_current_run(session)', transition_source)
        atomic_start = transition_source.index('with transaction.atomic():')
        run_lock = transition_source.index('_lock_current_run(session)')
        self.assertLess(atomic_start, run_lock)
        self.assertNotIn('select_for_update', transition_source[:atomic_start])
        self.assertGreaterEqual(transition_source.count('_transition_may_be_due'), 2)
