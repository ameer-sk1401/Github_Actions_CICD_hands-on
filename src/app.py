from flask import Flask

# Create an instance of the Flask class
app = Flask(__name__)

# Define a route for the home page
@app.route('/')
def home():
    return 'Hello, World! and the cicd handson was successful!'

# Define a route for a different page
@app.route('/about')
def about():
    return 'This is the About page.'

@app.route("/health")
def health():
    return "OK"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)


