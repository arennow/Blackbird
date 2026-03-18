format:
	just _impl_format

report_errors:
	just _impl_format --lint

_impl_format *ARGS:
	swiftformat {{ARGS}} .

test *ARGS:
	swift test {{ARGS}}