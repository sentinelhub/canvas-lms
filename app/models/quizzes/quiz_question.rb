#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Quizzes::QuizQuestion < ActiveRecord::Base
  self.table_name = 'quiz_questions'

  include Workflow

  attr_accessible :quiz, :quiz_group, :assessment_question, :question_data, :assessment_question_version
  attr_readonly :quiz_id
  belongs_to :quiz, class_name: 'Quizzes::Quiz'
  belongs_to :assessment_question
  belongs_to :quiz_group, class_name: 'Quizzes::QuizGroup'

  EXPORTABLE_ATTRIBUTES = [:id, :quiz_id, :quiz_group_id, :assessment_question_id, :question_data, :assessment_question_version, :position, :created_at, :updated_at, :workflow_state]
  EXPORTABLE_ASSOCIATIONS = [:quiz, :assessment_question, :quiz_group]
  TEXT_ONLY = 'text_only_question'

  before_save :validate_blank_questions
  before_save :infer_defaults
  before_save :create_assessment_question
  before_destroy :delete_assessment_question
  before_destroy :update_quiz
  validates_presence_of :quiz_id
  serialize :question_data
  after_save :update_quiz

  workflow do
    state :active
    state :deleted
  end

  scope :active, -> { where("workflow_state='active' OR workflow_state IS NULL") }

  def infer_defaults
    if !self.position && self.quiz
      if self.quiz_group
        self.position = (self.quiz_group.quiz_questions.active.map(&:position).compact.max || 0) + 1
      else
        self.position = self.quiz.root_entries_max_position + 1
      end
    end
  end

  protected :infer_defaults

  def update_quiz
    Quizzes::Quiz.mark_quiz_edited(self.quiz_id)
  end

  # @param [Hash] data
  # @param [String] data[:regrade_option]
  #  If present, the question will be regraded.
  #  You must also pass in data[:regrade_user] if you pass this option.
  #
  #  See Quizzes::QuizRegrader::Answer::REGRADE_OPTIONS for a rundown of the
  #  possible values for this parameter.
  #
  # @param [User] data[:regrade_user]
  #  The user/teacher who's performing the regrade (e.g, updating the question).
  #  Note that this is NOT an id, but an actual instance of a User model.
  def question_data=(in_data)
    data = if in_data.is_a?(String)
      ActiveSupport::JSON.decode(in_data)
    elsif in_data.is_a?(Hash)
      in_data.with_indifferent_access
    else
      in_data
    end

    if data[:regrade_option].present?
      update_question_regrade(data[:regrade_option], data[:regrade_user])
    end

    return if data == self.question_data

    data = AssessmentQuestion.parse_question(data, self.assessment_question)
    data[:name] = data[:question_name]

    write_attribute(:question_data, data.to_hash)
  end

  def question_data
    if data = read_attribute(:question_data)
      if data.class == Hash
        # TODO: a reader shouldn't write ?????????????????????
        data = write_attribute(:question_data, data.with_indifferent_access)
      end
    end

    unless data.is_a?(Quizzes::QuizQuestion::QuestionData)
      data = Quizzes::QuizQuestion::QuestionData.new(data || HashWithIndifferentAccess.new)
    end

    unless data[:id].present? && !self.id
      data[:id] = self.id
    end

    data
  end

  def delete_assessment_question
    if self.assessment_question && self.assessment_question.editable_by?(self)
      self.assessment_question.destroy
    end
  end

  def create_assessment_question
    return if self.question_data && self.question_data.is_type?(:text_only)
    self.assessment_question ||= AssessmentQuestion.new
    if self.assessment_question.editable_by?(self)
      self.assessment_question.question_data = self.question_data
      self.assessment_question.initial_context = self.quiz.context if self.quiz && self.quiz.context
      self.assessment_question.save if self.assessment_question.new_record?
      self.assessment_question_id = self.assessment_question.id
      self.assessment_question_version = self.assessment_question.version_number rescue nil
    end
    true
  end

  def validate_blank_questions
    return if self.question_data && !(self.question_data.is_type?(:fill_in_multiple_blanks) || self.question_data.is_type?(:short_answer))
    qd = self.question_data
    qd.answers = qd.answers.select { |answer| !answer['text'].empty? }
    self.question_data = qd
    self.question_data_will_change!
    true
  end

  def self.migrate_question_hash(hash, params)
    if params[:old_context] && params[:new_context]
      migrator = lambda { |value| Course.migrate_content_links(value, params[:old_context], params[:new_context]) }
    elsif params[:context] && params[:user]
      migrator = lambda { |value| Course.copy_authorized_content(value, params[:context], params[:user]) }
    else
      return hash
    end

    [:question_text, :correct_comments, :incorrect_comments, :neutral_comments, :text_after_answers].each do |key|
      hash[key] = migrator.call(hash[key]) if hash[key]
    end
    hash[:answers].each do |answer|
      [:html, :comments_html].each do |key|
        answer[key] = migrator.call(answer[key]) if answer[key].present?
      end
    end if hash[:answers]

    hash
  end

  def clone_for(quiz, dup=nil, options={})
    dup ||= Quizzes::QuizQuestion.new
    self.attributes.delete_if { |k, v| [:id, :quiz_id, :quiz_group_id, :question_data].include?(k.to_sym) }.each do |key, val|
      dup.send("#{key}=", val)
    end
    data = self.question_data || HashWithIndifferentAccess.new
    data.delete(:id)
    if options[:old_context] && options[:new_context]
      data = Quizzes::QuizQuestion.migrate_question_hash(data, options)
    end
    dup.write_attribute(:question_data, data)
    dup.quiz_id = quiz.id
    dup
  end

  # QuizQuestion.data is used when creating and editing a quiz, but
  # once the quiz is "saved" then the "rendered" version of the
  # quiz is stored in Quizzes::Quiz.quiz_data.  Hence, the teacher can
  # be futzing with questions and groups and not affect
  # the quiz, as students see it.
  def data
    res = (self.question_data || self.assessment_question.question_data) rescue Quizzes::QuizQuestion::QuestionData.new(HashWithIndifferentAccess.new)
    res[:assessment_question_id] = self.assessment_question_id
    res[:question_name] = t('#quizzes.quiz_question.defaults.question_name', "Question") if res[:question_name].blank?
    res[:id] = self.id

    res.to_hash
  end

  # All questions will be assigned to the given quiz_group, and will be
  # assigned as part of the root quiz if no group is given
  def self.update_all_positions!(questions, quiz_group=nil)
    return unless questions.size > 0

    group_id = quiz_group ? quiz_group.id : 'NULL'
    updates = questions.map do |q|
      "WHEN id=#{q.id.to_i} THEN #{q.position.to_i}"
    end

    set = "quiz_group_id=#{group_id}, position=CASE #{updates.join(" ")} ELSE id END"
    where(:id => questions).update_all(set)
  end

  def migrate_file_links
    Quizzes::QuizQuestionLinkMigrator.migrate_file_links_in_question(self)
  end

  def self.batch_migrate_file_links(ids)
    questions = Quizzes::QuizQuestion.includes(:quiz, :assessment_question).where(:id => ids)
    questions.each do |question|
      if question.migrate_file_links
        question.save
      end
    end
  end

  alias_method :destroy!, :destroy

  def destroy
    self.workflow_state = 'deleted'
    self.save
  end

  private

  def update_question_regrade(regrade_option, regrade_user)
    regrade = Quizzes::QuizRegrade.where(quiz_id: quiz.id, quiz_version: quiz.version_number).first_or_initialize
    if regrade.new_record?
      regrade.user = regrade_user
      regrade.save!
    end

    question_regrade = Quizzes::QuizQuestionRegrade.where(quiz_question_id: id, quiz_regrade_id: regrade.id).first_or_initialize
    question_regrade.quiz_regrade = regrade
    question_regrade.regrade_option = regrade_option
    question_regrade.save!
  end
end
