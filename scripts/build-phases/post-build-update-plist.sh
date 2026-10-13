#!/usr/bin/env bash
PLIST_FILE="$TARGET_BUILD_DIR/$INFOPLIST_PATH"

# Record when this binary was built so the About page can surface it for support.
# The numeric offset is included so the wall-clock reading isn't ambiguous across timezones.
if [ -f "$PLIST_FILE" ]; then
	build_date=$(date '+%Y-%m-%d %H:%M %z')
	plutil -remove BuildDate "$PLIST_FILE" 2>/dev/null || true
	if ! plutil -insert BuildDate -string "$build_date" "$PLIST_FILE"; then
		echo "error: failed to write BuildDate into $PLIST_FILE"
		exit 1
	fi
fi

if [ -f "$GOOGLE_SIGN_IN_SECRETS_PATH" ] && [ -f "$PLIST_FILE" ]; then
	# The CFBundleURLName key to look for
	replace_key="GoogleSignIn"

	# Get the URL Scheme
	url_scheme=$(cat $GOOGLE_SIGN_IN_SECRETS_PATH)

	# Grab the number of elements in the URL Types array
	count=$(plutil -extract CFBundleURLTypes raw -expect array $PLIST_FILE)
	# Loop through the URL Types array until we find the sign in item
	for (( i=0; i<$count; i++ )) do
		key=$(plutil -extract CFBundleURLTypes.$i.CFBundleURLName raw -expect string $PLIST_FILE)
		if [ "$key" == "$replace_key" ]; then 
			# Empty out the array, and then insert the scheme into the file
			plutil -replace CFBundleURLTypes.$i.CFBundleURLSchemes -array $PLIST_FILE
			plutil -insert CFBundleURLTypes.$i.CFBundleURLSchemes.0 -string $url_scheme $PLIST_FILE
		fi
	done
	exit 0
fi