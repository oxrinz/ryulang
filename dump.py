import ast
import os

def dump_ast_for_files(directory_path, file_extension='.py'):
    """
    Parse and dump the AST for all Python files in a directory.
    
    Args:
        directory_path (str): Path to the directory containing Python files
        file_extension (str): File extension to filter for (default: '.py')
    """
    for filename in os.listdir(directory_path):
        if filename.endswith(file_extension):
            file_path = os.path.join(directory_path, filename)
            
            # Read the file
            with open(file_path, 'r') as file:
                code = file.read()
            
            # Parse the AST
            try:
                tree = ast.parse(code, filename=filename)
                print(f"\n{'='*40}\nAST for {filename}:\n{'='*40}")
                print(ast.dump(tree, indent=2))
            except SyntaxError as e:
                print(f"Syntax error in {filename}: {e}")

# Example usage
dump_ast_for_files('./python')