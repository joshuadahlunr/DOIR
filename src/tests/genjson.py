import json
import random
import string
import tqdm

def generate_random_string(length):
	return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def generate_random_json_value(depth = 0):
	value_type = random.choice(['string', 'number', 'boolean', 'null', 'object', 'array'] if depth < 10 else ['string', 'number', 'boolean', 'null'])
	
	if value_type == 'string':
		return generate_random_string(random.randint(5, 15))
	elif value_type == 'number':
		return random.uniform(-1000, 1000)  # Random float between -1000 and 1000
	elif value_type == 'boolean':
		return random.choice([True, False])
	elif value_type == 'null':
		return None
	elif value_type == 'object':
		num_fields = random.randint(1, 5)  # Random number of fields for nested object
		nested_data = {}
		for _ in range(num_fields):
			field_name = generate_random_string(8)  # Random field name
			nested_data[field_name] = generate_random_json_value(depth + 1)
		return nested_data
	elif value_type == 'array':
		length = random.randint(1, 5)  # Random length for array
		return [generate_random_json_value(depth + 1) for _ in range(length)]

def generate_random_json():
	"""Generate a random JSON object with random number of fields."""
	num_fields = random.randint(3, 7)  # Random number of fields per JSON object
	data = {}
	for _ in range(num_fields):
		field_name = generate_random_string(8)  # Random field name
		field_value = generate_random_json_value()  # Random field value
		data[field_name] = field_value
	return data

def generate_json_file(filename, num_lines):
	"""Generate a JSON file with specified number of lines."""
	with open(filename, 'w') as f:
		f.write("R\"__JSON__([")
		for _ in tqdm.trange(num_lines):
			data = generate_random_json()
			json.dump(data, f)
			f.write(",\n")
		f.write("])__JSON__\"")

if __name__ == "__main__":
	num_lines = 1000
	filename = "random_data.json"
	random.seed(12345)
	generate_json_file(filename, num_lines)
	print(f"Generated {num_lines} lines of JSON data in {filename}")
