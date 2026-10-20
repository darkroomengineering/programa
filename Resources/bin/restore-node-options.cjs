const hadOriginalNodeOptions = process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
if (hadOriginalNodeOptions) {
  process.env.NODE_OPTIONS = process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS ?? "";
} else {
  delete process.env.NODE_OPTIONS;
}
delete process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS;
delete process.env.PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT;
