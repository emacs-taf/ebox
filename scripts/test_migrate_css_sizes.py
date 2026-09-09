"""Behavior and non-destructive migration tests; standard library only."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("migrate-css-sizes.py")
SPEC = importlib.util.spec_from_file_location("migrate_css_sizes", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class MigrationTests(unittest.TestCase):
    def migrate(self, source):
        migration = MODULE.Migration(source)
        result = migration.run()
        self.assertFalse(migration.reviews)
        second = MODULE.Migration(result)
        self.assertEqual(second.run(), result)
        self.assertFalse(second.reviews)
        return result

    def test_preserves_reader_quoting_and_text(self):
        source = '; :width 999\n`(box\t:width ( 240 ) :height 3 ":height 99" ,label)\n'
        self.assertEqual(self.migrate(source), '; :width 999\n`(box\t:width ( px 240 ) :height (lh 3) ":height 99" ,label)\n')

    def test_executable_calls_keep_values_quoted(self):
        self.assertEqual(self.migrate("(ebox-create :width 80 :height 3 :margin '(1 2))"),
                         "(ebox-create :width '(ch 80) :height '(lh 3) :margin '((lh 1) (ch 2)))")

    def test_scalar_and_edge_shorthands_preserve_axes(self):
        self.assertEqual(self.migrate("'(:padding 2 :margin (1 2 3 4) :gap (1 (12)) :border-width (1 2))"),
                         "'(:padding ((lh 2) (ch 2)) :margin ((lh 1) (ch 2) (lh 3) (ch 4)) :gap ((lh 1) (px 12)) :border-width ((px 1) (px 2)))")

    def test_one_edge_and_border_components(self):
        self.assertEqual(self.migrate("'(:padding (2) :margin-inline (3) :border (2 solid \"red\"))"),
                         "'(:padding ((lh 2) (ch 2)) :margin-inline ((ch 3)) :border ((px 2) solid \"red\"))")

    def test_grid_counts_and_legacy_row_tracks(self):
        self.assertEqual(self.migrate("'(grid :grid-template-columns ((repeat 2 (80)) (fr 1)) :grid-template-rows ((minmax (1) (3)) 1) :grid-row (2 :span 3))"),
                         "'(grid :grid-template-columns ((repeat 2 (px 80)) (fr 1)) :grid-template-rows ((minmax (lh 1) (lh 3)) (lh 1)) :grid-row (2 :span 3))")

    def test_keywords_and_numeric_non_sizes(self):
        self.assertEqual(self.migrate("'(:width viewport :height (viewport-height) :flex-grow 3 :order 2 :font-size 16 :border-top-width 1)"),
                         "'(:width (vw 100) :height (vh 100) :flex-grow 3 :order 2 :font-size 16 :border-top-width (px 1))")

    def test_flex_only_converts_basis(self):
        self.assertEqual(self.migrate("'(flex (box :flex (2 1 0)) (box :flex 2))"),
                         "'(flex (box :flex (2 1 (ch 0))) (box :flex 2))")
        self.assertEqual(self.migrate("'(flex :flex-direction column (box :flex (2 1 0) :flex-basis 3))"),
                         "'(flex :flex-direction column (box :flex (2 1 (lh 0)) :flex-basis (lh 3)))")

    def test_unknown_flex_axis_never_generates_pixel_zero(self):
        source = "'(:flex (2 1 0) :flex-basis (0))"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 2)

    def test_cross_axis_units_are_reported_recursively(self):
        source = "'(:height (px 0) :width (lh 2) :padding (ch 1) :gap (vw 2) :height (clamp (lh 1) (calc (* (px 2) 0)) (vh 20)))"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 5)
        self.assertTrue(all("invalid on this axis" in item[1] for item in migration.reviews))

    def test_legal_functions_edges_and_strokes_are_preserved(self):
        source = "'(:width (calc (- (vw 50) (ch 2))) :height (max (lh 2) (vh 10)) :padding ((lh 1) (px 2)) :border ((px 2) solid \"red\") :border-width (lh 0.1))"
        self.assertEqual(self.migrate(source), source)
        migration = MODULE.Migration("'(:border ((max (px 1) (% 2)) solid \"red\"))")
        self.assertEqual(migration.run(), migration.source)
        self.assertEqual(len(migration.reviews), 1)

    def test_grid_and_flex_lengths_use_their_actual_axis(self):
        source = "'(flex :flex-direction column-reverse (box :flex-basis (px 2)) (flex (box :flex-basis (lh 2))) (grid :grid-template-rows ((repeat 2 (minmax (lh 1) (px 4))))))"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 3)

    def test_cross_axis_legacy_viewports_require_review(self):
        source = "'(:width viewport-height :height (viewport))"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 2)

    def test_dynamic_function_operands_require_axis_review(self):
        source = "`(:height (calc (+ (lh 1) ,size)))"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 1)

    def test_legacy_row_gap_singletons_are_lines(self):
        self.assertEqual(self.migrate("'(:row-gap (2) :gap ((2) (3)))"),
                         "'(:row-gap (lh 2) :gap ((lh 2) (px 3)))")
        self.assertEqual(self.migrate("'(:gap (2))"), "'(:gap ((lh 2) (px 2)))")

    def test_ambiguous_singletons_and_max_auto_require_review(self):
        source = "'(:flex-basis (3) :padding-top (2) :max-width auto)"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 3)

    def test_native_display_specs_keep_their_own_size_grammar(self):
        source = "(list '(space :width (720) :height 2) '(image :width 30 :height 20))"
        self.assertEqual(self.migrate(source), source)

    def test_etaf_styles_macro_consumes_literal_values(self):
        self.assertEqual(self.migrate('(etaf-define-component card () :styles (styles ("&" :width 3 :padding (1 2))))'),
                         '(etaf-define-component card () :styles (styles ("&" :width (ch 3) :padding ((lh 1) (ch 2)))))')

    def test_callers_filter_preserves_measured_structs_and_limits_reviews(self):
        source = "(list :width 30 :height unknown (ebox-build '(box :width 4)) (ebox-create :height 3))"
        migration = MODULE.Migration(source, {"ebox-build", "ebox-create"})
        self.assertEqual(migration.run(),
                         "(list :width 30 :height unknown (ebox-build '(box :width (ch 4))) (ebox-create :height '(lh 3)))")
        self.assertFalse(migration.reviews)

    def test_static_etaf_data_keeps_sizes_unquoted(self):
        migration = MODULE.Migration('(box :width 20 :height 3)', literal=True)
        self.assertEqual(migration.run(), '(box :width (ch 20) :height (lh 3))')
        self.assertFalse(migration.reviews)

    def test_dynamic_and_removed_forms_report_without_guessing(self):
        source = "`(box :width ,width :height (fit-content 3) :max-width contain :flex-basis 2)"
        migration = MODULE.Migration(source)
        self.assertEqual(migration.run(), source)
        self.assertEqual(len(migration.reviews), 4)

    def test_reader_explicit_quote_and_char_literals(self):
        self.assertEqual(self.migrate('(list ?\\" ?\\( (quote (:width 20)) :height (quote 2))'),
                         '(list ?\\" ?\\( (quote (:width (ch 20))) :height (quote (lh 2)))')

    def test_cli_dry_run_write_and_syntax_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "demo.ebox")
            path.write_text("'(box :width 20)\n")
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("1 property edits", result.stdout)
            self.assertEqual(path.read_text(), "'(box :width 20)\n")
            result = subprocess.run([sys.executable, str(SCRIPT), "--write", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), "'(box :width (ch 20))\n")
            self.assertFalse(list(Path(directory).glob(".migrate-css-*")))
            path.write_text("'(box :width 20")
            result = subprocess.run([sys.executable, str(SCRIPT), "--write", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(path.read_text(), "'(box :width 20")

    def test_cli_preserves_cross_axis_values_and_writes_safe_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "demo.ebox")
            path.write_text("'(box :width 20 :height (px 3))\n")
            result = subprocess.run([sys.executable, str(SCRIPT), "--write", str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("unit is invalid on this axis", result.stdout)
            self.assertEqual(path.read_text(), "'(box :width (ch 20) :height (px 3))\n")
            self.assertFalse(list(Path(directory).glob(".migrate-css-*")))


if __name__ == "__main__":
    unittest.main()
