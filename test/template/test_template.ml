open! Core
open Maestro_template

let show ?(vars = `Object []) template =
  match Or_error.bind (Template.parse template) ~f:(Template.render ~vars) with
  | Ok rendered -> print_string [%string "|%{rendered}|"]
  | Error error -> print_s [%sexp (error : Error.t)]
;;

let issue_vars =
  Jsonaf.of_string
    {|{
      "issue": {
        "identifier": "MT-101",
        "title": "Fix the flux capacitor",
        "description": null,
        "state": "Todo",
        "priority": 2,
        "labels": ["backend", "urgent"],
        "blocked_by": [{"identifier": "MT-99", "state": "Done"}],
        "dispatchable": true,
        "url": "https://linear.app/x/issue/MT-101"
      },
      "attempt": null
    }|}
;;

let%expect_test "interpolation of nested fields, numbers, and booleans" =
  show
    ~vars:issue_vars
    "{{ issue.identifier }}: {{ issue.title }} (priority {{ issue.priority }}, \
     dispatchable={{ issue.dispatchable }})";
  [%expect {| |MT-101: Fix the flux capacitor (priority 2, dispatchable=true)| |}]
;;

let%expect_test "null renders as empty string - attempt on first run is strict-safe" =
  show ~vars:issue_vars "attempt[{{ attempt }}] description[{{ issue.description }}]";
  [%expect {| |attempt[] description[]| |}]
;;

let%expect_test "arrays render as concatenation, Liquid-style" =
  show ~vars:issue_vars "{{ issue.labels }}";
  [%expect {| |backendurgent| |}]
;;

let%expect_test "for loop over labels with local binding shadowing" =
  show ~vars:issue_vars "{% for label in issue.labels %}<{{ label }}>{% endfor %}";
  [%expect {| |<backend><urgent>| |}]
;;

let%expect_test "for loop over object list reaches fields of the binding" =
  show
    ~vars:issue_vars
    "{% for blocker in issue.blocked_by %}{{ blocker.identifier }}={{ blocker.state }}{% \
     endfor %}";
  [%expect {| |MT-99=Done| |}]
;;

let%expect_test "if/else - null and false are falsy; everything else is truthy" =
  let vars =
    Jsonaf.of_string {|{"nil": null, "no": false, "yes": true, "empty": "", "zero": 0}|}
  in
  show ~vars "{% if nil %}T{% else %}F{% endif %}";
  show ~vars "{% if no %}T{% else %}F{% endif %}";
  show ~vars "{% if yes %}T{% else %}F{% endif %}";
  show ~vars "{% if empty %}T{% else %}F{% endif %}";
  show ~vars "{% if zero %}T{% else %}F{% endif %}";
  [%expect {| |F||F||T||T||T| |}]
;;

let%expect_test "the reference default prompt template renders" =
  let default_template =
    String.concat_lines
      [ "You are working on an issue from the configured tracker."
      ; ""
      ; "Identifier: {{ issue.identifier }}"
      ; "Title: {{ issue.title }}"
      ; ""
      ; "Body:"
      ; "{% if issue.description %}"
      ; "{{ issue.description }}"
      ; "{% else %}"
      ; "No description provided."
      ; "{% endif %}"
      ]
  in
  show ~vars:issue_vars default_template;
  [%expect
    {|
    |You are working on an issue from the configured tracker.

    Identifier: MT-101
    Title: Fix the flux capacitor

    Body:

    No description provided.

    |
    |}]
;;

let%expect_test "unknown variable fails rendering (strict mode)" =
  show ~vars:issue_vars "{{ issue.titel }}";
  [%expect {| (template_render_error ("unknown variable" (path issue.titel))) |}]
;;

let%expect_test "unknown variable inside an if condition fails (strict mode)" =
  show ~vars:issue_vars "{% if issue.missing_field %}T{% endif %}";
  [%expect {| (template_render_error ("unknown variable" (path issue.missing_field))) |}]
;;

let%expect_test "any filter fails (strict mode - no filters implemented)" =
  show ~vars:issue_vars "{{ issue.title | upcase }}";
  [%expect
    {|
    (template_parse_error
     ("filters are not supported by this template engine (strict mode)"
      "issue.title | upcase"))
    |}]
;;

let%expect_test "unknown tag fails parsing" =
  show "{% assign x = 1 %}";
  [%expect
    {| (template_parse_error ("unknown or malformed template tag" "assign x = 1")) |}]
;;

let%expect_test "structural errors: unclosed blocks, stray terminators, unclosed markers" =
  show "{% if x %}no end";
  [%expect
    {| (template_parse_error ("unclosed template block" (expected "{% endif %}"))) |}];
  show "text {% endif %}";
  [%expect {| (template_parse_error "{% endif %} without a matching {% if %}") |}];
  show "{% for x in xs %}body";
  [%expect
    {| (template_parse_error ("unclosed template block" (expected "{% endfor %}"))) |}];
  show "{{ oops";
  [%expect
    {| (template_parse_error ("unclosed template marker" (marker {{) (at_offset 0))) |}];
  show "{% if a %}1{% else %}2{% else %}3{% endif %}";
  [%expect {| (template_parse_error "duplicate {% else %} in one {% if %}") |}]
;;

let%expect_test "looking up a field inside a scalar fails with context" =
  show ~vars:issue_vars "{{ issue.title.length }}";
  [%expect
    {|
    (template_render_error
     ("cannot look up a field inside a non-object value"
      (path issue.title.length) (field length)
      (value (String "Fix the flux capacitor"))))
    |}]
;;

let%expect_test "iterating a non-array and rendering an object both fail" =
  show ~vars:issue_vars "{% for x in issue.title %}{{ x }}{% endfor %}";
  [%expect
    {|
    (template_render_error
     ("cannot iterate over a non-array value" (path issue.title)
      (value (String "Fix the flux capacitor"))))
    |}];
  show ~vars:issue_vars "{{ issue }}";
  [%expect
    {|
    (template_render_error
     ("cannot render an object value"
      (value
       (Object
        ((identifier (String MT-101)) (title (String "Fix the flux capacitor"))
         (description Null) (state (String Todo)) (priority (Number 2))
         (labels (Array ((String backend) (String urgent))))
         (blocked_by
          (Array ((Object ((identifier (String MT-99)) (state (String Done)))))))
         (dispatchable True) (url (String https://linear.app/x/issue/MT-101)))))))
    |}]
;;
