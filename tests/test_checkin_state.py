import sys
from pathlib import Path

project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from checkin import (
	append_account_notification,
	format_check_in_notification,
	generate_balance_hash,
)


def test_balance_hash_changes_when_quota_changes():
	before = {'account_1': {'quota': 100.0, 'used': 20.0}}
	after = {'account_1': {'quota': 125.0, 'used': 20.0}}

	assert generate_balance_hash(before) != generate_balance_hash(after)


def test_balance_hash_changes_when_used_quota_changes():
	before = {'account_1': {'quota': 100.0, 'used': 20.0}}
	after = {'account_1': {'quota': 100.0, 'used': 21.0}}

	assert generate_balance_hash(before) != generate_balance_hash(after)


def test_balance_hash_is_stable_for_equivalent_balances():
	left = {
		'account_2': {'quota': 50.0, 'used': 1.0},
		'account_1': {'quota': 100.0, 'used': 20.0},
	}
	right = {
		'account_1': {'used': 20.0, 'quota': 100.0},
		'account_2': {'used': 1.0, 'quota': 50.0},
	}

	assert generate_balance_hash(left) == generate_balance_hash(right)


def test_account_notification_dedupes_by_account_key_not_name_substring():
	notifications = ['[CHECK-IN] agent github2\n  当前余额: $69.79']
	notified_account_keys = {'account_2'}

	append_account_notification(
		notifications,
		notified_account_keys,
		'account_3',
		'[CHECK-IN] agent github\n  当前余额: $74.63',
	)

	assert notifications == [
		'[CHECK-IN] agent github2\n  当前余额: $69.79',
		'[CHECK-IN] agent github\n  当前余额: $74.63',
	]
	assert notified_account_keys == {'account_2', 'account_3'}


def test_auto_check_in_notification_shows_current_balance_without_before_after_delta():
	detail = {
		'name': 'agent github',
		'before_quota': 69.79,
		'before_used': 230.21,
		'after_quota': 69.79,
		'after_used': 230.21,
		'check_in_reward': 0,
		'usage_increase': 0,
		'balance_change': 0,
		'auto_check_in': True,
		'success': True,
	}

	result = format_check_in_notification(detail)

	assert '当前余额: $69.79' in result
	assert '累计消耗: $230.21' in result
	assert '签到前' not in result
	assert '签到后' not in result
	assert '签到获得' not in result
