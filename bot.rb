require 'telegram/bot'
require 'net/http'
require 'uri'
require 'json'
require 'dotenv/load'

# Load keys from .env
TELEGRAM_BOT_TOKEN = ENV['TELEGRAM_BOT_TOKEN']
OPENAI_API_KEY = ENV['OPENAI_API_KEY']

class QuizBot
  attr_accessor :questions, :current_question, :score

  def initialize
    @questions = []
    @current_question = 0
    @score = 0
    puts "Initialized new QuizBot instance"
  end

  # Fetch questions from OpenAI
  def fetch_questions(topic, bot, chat_id)
    question_count = 10
    puts "Fetching questions for topic: #{topic}"
    prompt = <<-PROMPT
Generate a list of #{question_count} multiple-choice quiz questions in XML format in Russian about the topic: "#{topic}". The XML should follow this structure:
<questions>
  <question>
    <title>Текст вопроса здесь</title>
    <answers>
      <answer letter="A" correct="false">Вариант ответа 1</answer>
      <answer letter="B" correct="false">Вариант ответа 2</answer>
      <answer letter="C" correct="true">Вариант ответа 3</answer>
      <answer letter="D" correct="false">Вариант ответа 4</answer>
    </answers>
    <explanation>Подробное объяснение правильного ответа</explanation>
  </question>
  ...
</questions>

Make each question specific, informative, and accurate. Each question should have four different answer options, with only one correct answer marked as correct="true". Provide a full explanation in Russian for why the correct answer is correct. Avoid repeating questions or explanations. Add emojis where appropriate.

**Important**: Output **only** the XML code. Do **not** include Markdown formatting, code blocks, or any additional text.

PROMPT

    uri = URI("https://api.openai.com/v1/chat/completions")
    puts "OpenAI API URI: #{uri}"

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{OPENAI_API_KEY}"
    request_body = {
      model: "gpt-4o",
      messages: [
        { role: "system", content: "You are a helpful assistant that generates quiz questions in XML format in Russian. You answer with XML." },
        { role: "user", content: prompt }
      ],
      max_tokens: 4000,
      temperature: 0.7,
      n: 1
    }
    request.body = JSON.dump(request_body)
    puts "Request body: #{request.body}"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      puts "Sending request to OpenAI API..."
      bot.api.send_message(chat_id: chat_id, text: "Генерирую викторину, это может занять до 1 минуты")
      http.request(request)
    end

    puts "Received response with status code: #{response.code}"
    response_data = JSON.parse(response.body)
    puts "Response data: #{response_data}"

    if response.code.to_i != 200
      error_message = response_data['error']['message']
      puts "OpenAI API Error: #{error_message}"
      return
    end

    if response_data['choices'] && response_data['choices'][0] && response_data['choices'][0]['message']
      xml_data = response_data['choices'][0]['message']['content']
      puts "Received XML data from OpenAI:"
      puts xml_data
      parse_questions_from_xml(xml_data)
    else
      puts "OpenAI API returned unexpected response: #{response.body}"
    end
  end

  # Parse XML questions into an array
  def parse_questions_from_xml(xml)
    puts "Parsing XML data..."
    require 'nokogiri'
    doc = Nokogiri::XML(xml)
    if doc.errors.any?
      puts "XML Parsing errors:"
      doc.errors.each { |error| puts error }
      return
    end
    doc.xpath("//question").each_with_index do |q, index|
      title = q.xpath("title").text.strip
      answers = q.xpath("answers/answer").map do |answer|
        {
          letter: answer['letter'],
          text: answer.text.strip,
          correct: answer['correct'] == "true"
        }
      end
      explanation = q.xpath("explanation").text.strip
      @questions << { title: title, answers: answers, explanation: explanation }
      puts "Parsed question #{index + 1}: #{title}"
    end
    puts "Total questions parsed: #{@questions.size}"
  end

  # Get the current question text
  def current_question_text
    question = @questions[@current_question]
    answer_options = question[:answers].map do |a|
      "#{a[:letter]}) #{a[:text]}"
    end.join("\n")
    "#{question[:title]}\n\n#{answer_options}"
  end

  # Check the answer
  def check_answer(answer_letter)
    answer_letter = answer_letter.upcase
    current_answers = @questions[@current_question][:answers]
    selected_answer = current_answers.find { |a| a[:letter] == answer_letter }
    if selected_answer && selected_answer[:correct]
      @score += 1
      puts "User answered correctly."
      "Правильно! 🎉\n\n#{@questions[@current_question][:explanation]}"
    else
      puts "User answered incorrectly."
      "Неверно. 😞\n\n#{@questions[@current_question][:explanation]}"
    end
  end
end

# Initialize the bot
quizzes = {}
puts "Starting Telegram bot..."

Telegram::Bot::Client.run(TELEGRAM_BOT_TOKEN) do |bot|
  bot.listen do |message|
    chat_id = message.chat.id
    puts "Received message from chat_id #{chat_id}: #{message.text.inspect}"

    quizzes[chat_id] ||= QuizBot.new
    quiz = quizzes[chat_id]

    case message.text
    when '/start'
      puts "User #{chat_id} started a new quiz."
      quizzes[chat_id] = QuizBot.new  # Reset quiz for this user
      bot.api.send_message(chat_id: chat_id, text: "Привет! Введите тему викторины:")
    else
      if quiz.questions.empty?
        # Fetch questions based on the provided topic
        topic = message.text.strip
        puts "User #{chat_id} provided topic: #{topic}"
        quiz.fetch_questions(topic, bot, chat_id)

        if quiz.questions.empty?
          bot.api.send_message(chat_id: chat_id, text: "Не удалось получить вопросы по теме '#{topic}'. Попробуйте другую тему.")
          quizzes[chat_id] = QuizBot.new  # Reset quiz
        else
          bot.api.send_message(chat_id: chat_id, text: "Викторина по теме '#{topic}' готова! Нажмите 'Начать', чтобы начать.")

          bot.api.send_message(
            chat_id: chat_id,
            text: "Начать",
            reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
              keyboard: [[{ text: "Начать" }]],
              resize_keyboard: true
            )
          )
        end
      else
        case message.text
        when 'Начать', 'Дальше'
          if quiz.current_question < quiz.questions.size
            question_text = quiz.current_question_text
            buttons = quiz.questions[quiz.current_question][:answers].map do |a|
                [{ text: a[:letter] }]  # Now each button is a hash with a 'text' key
            end
            puts "Sending question #{quiz.current_question + 1} to user #{chat_id}"
            bot.api.send_message(
              chat_id: chat_id,
              text: question_text,
              reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: buttons, resize_keyboard: true)
            )
          else
            puts "Quiz completed for user #{chat_id}. Score: #{quiz.score}/#{quiz.questions.size}"
            bot.api.send_message(chat_id: chat_id, text: "Викторина завершена! Ваш результат: #{quiz.score} из #{quiz.questions.size}.")
            quizzes.delete(chat_id)  # Reset quiz
          end
        else
          # Check the answer
          puts "User #{chat_id} selected answer: #{message.text}"
          response = quiz.check_answer(message.text)
          bot.api.send_message(chat_id: chat_id, text: response)
          quiz.current_question += 1
          if quiz.current_question < quiz.questions.size
              bot.api.send_message(
                chat_id: chat_id,
                text: "Нажмите 'Дальше' для следующего вопроса.",
                reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
                  keyboard: [[{ text: "Дальше" }]],
                  resize_keyboard: true
                )
              )
          else
            puts "Quiz completed for user #{chat_id}. Score: #{quiz.score}/#{quiz.questions.size}"
            bot.api.send_message(chat_id: chat_id, text: "Викторина завершена! Ваш результат: #{quiz.score} из #{quiz.questions.size}.", reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true))
            bot.api.send_message(chat_id: chat_id, text: "Нажмите '/start', чтобы начать новую викторину.")
            quizzes.delete(chat_id)  # Reset quiz
          end
        end
      end
    end
  end
end
