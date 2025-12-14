import argparse
import os
import sys
import xml.etree.ElementTree as ET

WS = os.path.abspath('').replace('\\','/')

if __name__ == '__main__':
	# Parse arguments 
	parser = argparse.ArgumentParser()
	parser.add_argument('coverage_file', help='Path to the coverage XML file to relativize.')
	parser.add_argument('--output', '-o', help='Path to save the modified coverage XML file. If not provided, overwrites the input file.', default=None)
	parser.add_argument('--placeholder', '-p', help='Placeholder to use for the workspace path.', required=True)
	args = parser.parse_args()
	coverage_file = os.path.abspath(args.coverage_file)
	output_file = os.path.abspath(args.output) or coverage_file
	placeholder = args.placeholder

	# Check if the coverage file exists
	if not os.path.isfile(coverage_file):
		print(f"Error: Coverage file '{coverage_file}' does not exist.", file=sys.stderr)
		sys.exit(1)

	# Parse the XML file
	tree = ET.parse(coverage_file)
	root = tree.getroot()
	
	# Assume only one <source> element
	# Example source: <source>D:</source>
	source = root.findall('.//source')[0] if root.findall('.//source') else None
	if source is None:
		print("Error: No <source> element found in the coverage file.", file=sys.stderr)
		sys.exit(1)

	# Retrieve and modify source text
	source_text = source.text or ''
	substracted = WS
	if WS.startswith(source_text.replace('\\','/')):
		substracted = substracted.replace(source_text.replace('\\','/'), '').lstrip('/')
	source.text = placeholder

	# Modify packages to remove workspace path
	for package in root.findall('.//package'):
		package_name = package.get('name') or ''
		package_name = package_name.replace('\\','/').replace(WS, '').lstrip('/')
		package.set('name', package_name)

	# Modify filenames in <class> elements removing subtracted workspace path
	for file_class in root.findall('.//class'):
		filename = file_class.get('filename') or ''
		filename = filename.replace('\\','/').replace(substracted, '').lstrip('/')
		file_class.set('filename', filename)

	# Write the results to the output file
	tree.write(output_file, encoding='utf-8', xml_declaration=True)
