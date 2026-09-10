# Startup preferences and nearby answers

Settings now opens to General. **Prefer Start Mode** selects Auto, Local, or Cloud;
**Show sidebar** controls whether chat history is initially visible. Both preferences
are saved and applied at launch, New Chat, and a new Selection Context session.
Changing them does not interrupt the current conversation. Hiding and reopening the
same panel preserves its current mode and sidebar. Existing defaults remain Auto
with the sidebar hidden. The settings title bar uses the forest backdrop's top green.

Response guidance is shared by local inference, cloud providers, Screen, and File
Mode. Everyday answers aim for one short paragraph or 3–5 brief bullets, usually
under 150 words. This is a soft style preference: requested depth, complete edits,
code, and essential details take precedence. Output token limits are unchanged.

## Location and web search

With automatic web search configured, questions such as “What is the weather
forecast today?” and “What are some good restaurants around me?” request an
approximate location. Manual Web Search works too. Explicit cities, quoted text,
editing requests, and location/web opt-outs do not trigger device location.
The detector covers common English nearby and weather phrasing; it is a local
policy, not an additional model or network classification call.

Core Location requests permission only when a qualifying search is submitted.
A one-shot request uses kilometer accuracy and rounds coordinates to two decimal
places before Apple MapKit reverse geocoding, Brave Search, or model context.
The search query and current answer context include the approximate area. The
location envelope is not saved in the user's prompt or reused on later requests;
the assistant's answer may name the area and is saved normally as chat history.
There is no background tracking or persistent location cache.

General settings includes an off switch and a link to macOS Location Services.
Denied, disabled, or unavailable location preserves the draft and asks the user
to provide a city; no locationless nearby search is sent. Requests time out after
20 seconds and cancel on Stop/New Chat. Stale callbacks cannot affect a replacement
request. Without web search setup, normal chat remains available and the model is
instructed to ask for a city and avoid inventing current conditions.

Apple API references: [Core Location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services),
[macOS usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationusagedescription),
and [MapKit reverse geocoding](https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest).

## Verification

Regression coverage includes nearby/explicit-city/quoted/opt-out detection,
coordinate rounding, disabled settings, Local/Cloud/Auto search integration,
location failure and cancellation, saved prompt isolation, preference persistence,
invalid preference fallback, the title bar color, and rendering all settings pages.
Tests use location and search fixtures, not the developer's real location.
Run the required build, test suite, and analyzer with `scripts/verify-xcode.sh`.

For live permission verification, run the stable Apple Development-signed app
from Xcode, configure Brave Search, and submit a nearby question. Check Allow,
Deny, settings off, and Stop while locating. Do not launch the isolated unsigned
verification app interactively, since doing so can invalidate Screen Recording
consent. Live OS permission prompts and actual location accuracy are not proven
by fixture tests.
